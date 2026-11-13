import { createPrivateKey } from 'node:crypto';
import type { Output } from '@pulumi/pulumi';
import { secret } from '@pulumi/pulumi';
import { z } from 'zod';
import { findResticBackup } from './find-restic-backup.ts';
import { findVariable } from './find-variable.ts';
import { boxxyNoticeSessionKey, parseBoxxyNoticeSession } from './parse-boxxy-notice-session.ts';
import { boxxyReposKey, parseBoxxyRepos } from './parse-boxxy-repos.ts';
import { parseStackObject } from './parse-stack-object.ts';
import { requireGHCRPullCredential } from './require-ghcr-pull-credential.ts';
import { requirePinnedImage } from './require-pinned-image.ts';
import { requireVariable } from './require-variable.ts';
import type {
  BackupImage,
  BoxxyBackupInputs,
  BoxxyInputs,
  BoxxyRepos,
  Environment,
  StackConfig,
} from './types.ts';

const tokenNeed = 'the boxxy server needs it while stack config "boxxy" is set';

const pepysNeed =
  'the boxxy server signs its facts with it while stack config "boxxy.pepys" is set';

const name = z.string().min(1);

const publicURLMessage =
  'must be the https:// origin clients reach, with no path, such as https://boxxy.example.com';

const folders = z.array(name);

// the image reaches its own check below, which names what the field must hold
const boxxyConfigSchema = z.strictObject({
  image: z.string().optional(),
  runner: name,
  atc: z.strictObject({ trustedFolders: z.record(name, folders) }),
  spawn: z.strictObject({
    target: name,

    // the atc agents whose broker profile holds the read-only clone token; with one, the server
    // runs its review gate, which needs the noslop App's keys and the github section
    reviewAgents: z.array(name).optional(),
  }),

  // the environment whose deploy the stage times count; the cluster sets pepys's addresses
  pepys: z.strictObject({ environment: name }).optional(),

  // GitHub's REST root, which the pull request watch and the hook's link read
  github: z.strictObject({ baseUrl: z.url() }).optional(),

  // the owner's MCP tools behind OAuth, on a tunnel of its own; the cluster sets the port
  publicDoor: z
    .strictObject({
      publicURL: z
        .url({ protocol: /^https$/u, error: publicURLMessage })
        .refine((url) => new URL(url).origin === url, publicURLMessage),

      // the socket peers whose forwarded client address the door's security events trust
      trustForwardedFrom: z.array(name),
    })
    .optional(),
});

// setting stack config "boxxy" approves the deploy; BOXXY_RESTIC_* and BOXXY_R2_* add the backup
export function loadBoxxyInputs(
  stackConfig: Pick<StackConfig, 'getObject' | 'getSecret'>,
  env: Environment,
  backupImage: BackupImage | undefined,
): { readonly boxxy?: BoxxyInputs } {
  const raw = stackConfig.getObject('boxxy');

  if (raw === undefined) {
    return {};
  }

  const config = parseStackObject('boxxy', raw, boxxyConfigSchema);

  requirePinnedImage('boxxy.image', config.image);

  const spawnRepos = requireRepos(stackConfig);
  const workerToken = requireVariable(env, 'BOXXY_WORKER_TOKEN', tokenNeed);
  const atcToken = requireVariable(env, 'BOXXY_ATC_TOKEN', tokenNeed);

  if (workerToken === atcToken) {
    throw new Error('BOXXY_WORKER_TOKEN and BOXXY_ATC_TOKEN must differ');
  }

  const notice = findNotice(stackConfig, env, [workerToken, atcToken]);

  // the server signs each batch of facts with it; pepys ingest holds the same item
  const pepysSigningSecret =
    config.pepys === undefined
      ? undefined
      : requireVariable(env, 'BOXXY_PEPYS_SIGNING_SECRET', pepysNeed);

  const githubApp = config.github === undefined ? undefined : requireGithubApp(env);
  const reviewApp = findReviewApp(config, env);
  const pull = requireGHCRPullCredential(env);
  const backup = findBackup(env, backupImage);

  return {
    boxxy: {
      config: {
        image: config.image,
        runner: config.runner,
        atc: config.atc,
        spawn: {
          target: config.spawn.target,
          ...(config.spawn.reviewAgents === undefined
            ? {}
            : { reviewAgents: config.spawn.reviewAgents }),
        },
        ...(config.pepys === undefined ? {} : { pepys: config.pepys }),
        ...(config.github === undefined ? {} : { github: config.github }),
        ...(config.publicDoor === undefined ? {} : { publicDoor: config.publicDoor }),
      },
      repos: spawnRepos,
      pullCredential: { username: pull.username, token: secret(pull.token) },
      secrets: {
        workerToken: secret(workerToken),
        atcToken: secret(atcToken),
        ...(pepysSigningSecret === undefined
          ? {}
          : { pepysSigningSecret: secret(pepysSigningSecret) }),
        ...(githubApp === undefined ? {} : { githubApp }),
        ...(reviewApp === undefined ? {} : { reviewApp }),
        ...(notice === undefined ? {} : { notice }),
      },
      ...(backup === undefined ? {} : { backup }),
    },
  };
}

function requireRepos(stackConfig: Pick<StackConfig, 'getSecret'>): Output<BoxxyRepos> {
  const raw = stackConfig.getSecret(boxxyReposKey);

  if (raw === undefined) {
    throw new Error(
      `stack config "${boxxyReposKey}" is unset; the boxxy server spawns only in the repos it names: run \`pulumi config set --secret ${boxxyReposKey} < <file of JSON>\` in infra/`,
    );
  }

  return raw.apply(parseBoxxyRepos);
}

const noticeTokenVariable = 'BOXXY_ATC_NOTICE_TOKEN';

// The server refuses a notice session with no notice token. atc refuses a token file that holds
// one token twice, and every worker session holds the worker token, so the notice token is its own.
function findNotice(
  stackConfig: Pick<StackConfig, 'getSecret'>,
  env: Environment,
  otherTokens: readonly string[],
): NonNullable<BoxxyInputs['secrets']['notice']> | undefined {
  const session = stackConfig.getSecret(boxxyNoticeSessionKey);
  const token = findVariable(env, noticeTokenVariable);

  if (session === undefined && token === undefined) {
    return undefined;
  }

  if (session === undefined) {
    throw new Error(
      `${noticeTokenVariable} is set, but stack config "${boxxyNoticeSessionKey}" is unset: the server sends notices only to the session it names, so set both or neither: run \`pulumi config set --secret ${boxxyNoticeSessionKey} <gateway ID>\` in infra/`,
    );
  }

  if (token === undefined) {
    throw new Error(
      `stack config "${boxxyNoticeSessionKey}" is set, but ${noticeTokenVariable} is unset: the boxxy server refuses to start with a notice session and no notice token`,
    );
  }

  if (otherTokens.includes(token)) {
    throw new Error(
      `${noticeTokenVariable} must differ from BOXXY_WORKER_TOKEN and BOXXY_ATC_TOKEN`,
    );
  }

  return { session: session.apply(parseBoxxyNoticeSession), token: secret(token) };
}

const githubAppNeed =
  'the boxxy server calls GitHub as the boxxy App with it while stack config "boxxy.github" is set';

const installationIDPattern = /^[1-9]\d*$/u;
const clientIDPattern = /^\S+$/u;

// The pod has no broker to add a GitHub credential, so the github section needs the App's keys. A
// server refuses to start on a key of the wrong shape, which leaves the StatefulSet with no pod, so
// the deploy checks the shapes the server checks first, naming the variable and never its value.
function requireGithubApp(env: Environment): NonNullable<BoxxyInputs['secrets']['githubApp']> {
  const clientID = requireVariable(env, 'BOXXY_GITHUB_APP_CLIENT_ID', githubAppNeed);
  const privateKey = requireVariable(env, 'BOXXY_GITHUB_APP_PRIVATE_KEY', githubAppNeed);
  const installationID = requireVariable(env, 'BOXXY_GITHUB_APP_INSTALLATION_ID', githubAppNeed);

  if (!clientIDPattern.test(clientID)) {
    throw new Error("BOXXY_GITHUB_APP_CLIENT_ID must be the App's client ID, with no whitespace");
  }

  if (
    !installationIDPattern.test(installationID) ||
    !Number.isSafeInteger(Number(installationID))
  ) {
    throw new Error("BOXXY_GITHUB_APP_INSTALLATION_ID must be the App installation's numeric ID");
  }

  if (!isRSAPrivateKey(privateKey)) {
    throw new Error("BOXXY_GITHUB_APP_PRIVATE_KEY must be the App's RSA private key, in PEM form");
  }

  return {
    clientID: secret(clientID),
    privateKey: secret(privateKey),
    installationID: secret(installationID),
  };
}

// GitHub takes only an RS256 JWT, so a key of any other type can't sign it
function isRSAPrivateKey(pem: string): boolean {
  try {
    return createPrivateKey(pem).asymmetricKeyType === 'rsa';
  } catch {
    return false;
  }
}

const reviewAppNeed =
  'the boxxy server posts each review as the noslop App with it while stack config "boxxy.spawn.reviewAgents" lists an agent';

// The noslop App's keys, which only the server's pod holds: the review gate checks and posts each
// review session's result with them. A server with review agents and no keys or no github section
// rejects every review close-out, so the deploy refuses that pairing.
function findReviewApp(
  config: z.infer<typeof boxxyConfigSchema>,
  env: Environment,
): NonNullable<BoxxyInputs['secrets']['reviewApp']> | undefined {
  if ((config.spawn.reviewAgents ?? []).length === 0) {
    return undefined;
  }

  if (config.github === undefined) {
    throw new Error(
      'stack config "boxxy.spawn.reviewAgents" needs stack config "boxxy.github": the review gate reads the pull request\'s changes through it',
    );
  }

  return {
    appID: secret(requireVariable(env, 'NOSLOP_GITHUB_APP_ID', reviewAppNeed)),
    privateKey: secret(requireVariable(env, 'NOSLOP_GITHUB_APP_PRIVATE_KEY', reviewAppNeed)),
    installationID: secret(
      requireVariable(env, 'NOSLOP_GITHUB_APP_INSTALLATION_ID', reviewAppNeed),
    ),
  };
}

function findBackup(
  env: Environment,
  backupImage: BackupImage | undefined,
): BoxxyBackupInputs | undefined {
  const backup = findResticBackup(env, {
    prefix: 'BOXXY',
    label: "the boxxy server's backup",
    path: 'boxxy',
  });

  if (backup === undefined) {
    return undefined;
  }

  if (backupImage === undefined) {
    throw new Error(
      'the boxxy backup runs in stack config "atcGateway.backupImage", which is unset: set atcGateway, or unset the BOXXY backup variables',
    );
  }

  return {
    image: backupImage.reference,
    secrets: {
      repository: secret(backup.repository),
      password: secret(backup.password),
      accessKeyID: secret(backup.accessKeyID),
      secretAccessKey: secret(backup.secretAccessKey),
    },
  };
}

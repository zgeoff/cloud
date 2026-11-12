import type { Output } from '@pulumi/pulumi';
import { secret } from '@pulumi/pulumi';
import { z } from 'zod';
import { findResticBackup } from './find-restic-backup.ts';
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

const githubNeed =
  'the boxxy server reads pull requests with it while stack config "boxxy.github" is set';

const name = z.string().min(1);
const folders = z.array(name);

// the image reaches its own check below, which names what the field must hold
const boxxyConfigSchema = z.strictObject({
  image: z.string().optional(),
  runner: name,
  atc: z.strictObject({
    trustedFolders: z.record(name, folders),
    noticeSession: name.optional(),
  }),
  spawn: z.strictObject({ target: name }),

  // the environment whose deploy the stage times count; the cluster sets pepys's addresses
  pepys: z.strictObject({ environment: name }).optional(),

  // GitHub's REST root, which the pull request watch and the hook's link read
  github: z.strictObject({ baseUrl: z.url() }).optional(),
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

  // the server signs each batch of facts with it; pepys ingest holds the same item
  const pepysSigningSecret =
    config.pepys === undefined
      ? undefined
      : requireVariable(env, 'BOXXY_PEPYS_SIGNING_SECRET', pepysNeed);

  // the pod has no broker to add a GitHub credential, so a private repo needs the token
  const githubToken =
    config.github === undefined
      ? undefined
      : requireVariable(env, 'BOXXY_GITHUB_TOKEN', githubNeed);

  const pull = requireGHCRPullCredential(env);
  const backup = findBackup(env, backupImage);

  return {
    boxxy: {
      config: {
        image: config.image,
        runner: config.runner,
        atc: {
          trustedFolders: config.atc.trustedFolders,
          ...(config.atc.noticeSession === undefined
            ? {}
            : { noticeSession: config.atc.noticeSession }),
        },
        spawn: config.spawn,
        ...(config.pepys === undefined ? {} : { pepys: config.pepys }),
        ...(config.github === undefined ? {} : { github: config.github }),
      },
      repos: spawnRepos,
      pullCredential: { username: pull.username, token: secret(pull.token) },
      secrets: {
        workerToken: secret(workerToken),
        atcToken: secret(atcToken),
        ...(pepysSigningSecret === undefined
          ? {}
          : { pepysSigningSecret: secret(pepysSigningSecret) }),
        ...(githubToken === undefined ? {} : { githubToken: secret(githubToken) }),
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

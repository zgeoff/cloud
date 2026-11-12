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
      },
      repos: spawnRepos,
      pullCredential: { username: pull.username, token: secret(pull.token) },
      secrets: { workerToken: secret(workerToken), atcToken: secret(atcToken) },
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

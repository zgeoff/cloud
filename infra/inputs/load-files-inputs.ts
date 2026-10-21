import { createHash } from 'node:crypto';
import { secret } from '@pulumi/pulumi';
import { z } from 'zod';
import { findResticBackup } from './find-restic-backup.ts';
import { parseStackObject } from './parse-stack-object.ts';
import { requireGeoffCloudHostname } from './require-geoff-cloud-hostname.ts';
import { requireGHCRPullCredential } from './require-ghcr-pull-credential.ts';
import { requirePinnedImage } from './require-pinned-image.ts';
import { requireVariable } from './require-variable.ts';
import type {
  BackupImage,
  Environment,
  FilesBackupInputs,
  FilesInputs,
  StackConfig,
} from './types.ts';

const tokenNeed = 'the files service needs it while stack config "files" is set';

// a missing field reaches its own check below, which names what the field must hold
const filesConfigSchema = z.object({
  image: z.string().optional(),
  hostname: z.string().optional(),
});

// setting stack config "files" approves the deploy; FILES_RESTIC_* and FILES_R2_* add the backup
export function loadFilesInputs(
  stackConfig: Pick<StackConfig, 'getObject'>,
  env: Environment,
  backupImage: BackupImage | undefined,
): { readonly files?: FilesInputs } {
  const raw = stackConfig.getObject('files');

  if (raw === undefined) {
    return {};
  }

  const config = parseStackObject('files', raw, filesConfigSchema);

  requirePinnedImage('files.image', config.image);
  requireGeoffCloudHostname('files.hostname', config.hostname);

  const agent = deriveTokenHash(requireVariable(env, 'FILES_AGENT_TOKEN', tokenNeed));
  const owner = deriveTokenHash(requireVariable(env, 'FILES_OWNER_TOKEN', tokenNeed));

  if (agent === owner) {
    throw new Error('FILES_AGENT_TOKEN and FILES_OWNER_TOKEN must differ');
  }

  const pull = requireGHCRPullCredential(env);
  const backup = findBackup(env, backupImage);

  return {
    files: {
      config: { image: config.image, hostname: config.hostname },
      pullCredential: { username: pull.username, token: secret(pull.token) },
      tokenHashes: { agent: secret(agent), owner: secret(owner) },
      ...(backup === undefined ? {} : { backup }),
    },
  };
}

function deriveTokenHash(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}

function findBackup(
  env: Environment,
  backupImage: BackupImage | undefined,
): FilesBackupInputs | undefined {
  const backup = findResticBackup(env, {
    prefix: 'FILES',
    label: "the files service's backup",
    path: 'files',
  });

  if (backup === undefined) {
    return undefined;
  }

  if (backupImage === undefined) {
    throw new Error(
      'the files backup runs in stack config "atcGateway.backupImage", which is unset: set atcGateway, or unset the FILES backup variables',
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

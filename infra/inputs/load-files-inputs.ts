import { createHash } from 'node:crypto';
import { secret } from '@pulumi/pulumi';
import { findResticBackup } from './find-restic-backup.ts';
import { requireGeoffCloudHostname } from './require-geoff-cloud-hostname.ts';
import { requireGHCRPullCredential } from './require-ghcr-pull-credential.ts';
import { requirePinnedImage } from './require-pinned-image.ts';
import { requireVariable } from './require-variable.ts';
import type {
  BackupImage,
  Environment,
  FilesBackupInputs,
  FilesConfig,
  FilesInputs,
  StackConfig,
} from './types.ts';

// why each role token is required, for requireVariable's error
const tokenNeed = 'the files service needs it while stack config "files" is set';

// The files service's inputs, or nothing while "files" is unset (setting it approves the deploy).
// The service reads only the SHA-256 of each role token, FILES_AGENT_TOKEN and FILES_OWNER_TOKEN.
// FILES_RESTIC_* and FILES_R2_* add the backup, in the gateway's backup image.
export function loadFilesInputs(
  stackConfig: Pick<StackConfig, 'getObject'>,
  env: Environment,
  backupImage: BackupImage | undefined,
): { readonly files?: FilesInputs } {
  const config = stackConfig.getObject<FilesConfig>('files');

  if (config === undefined) {
    return {};
  }

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

// all backup variables set, or no backup; findResticBackup throws on a partial set
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

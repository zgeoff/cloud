import type { Output } from '@pulumi/pulumi';
import type { NixieBackupInputs } from '../inputs/index.ts';

// the nixie-backup job's environment: it hands each repo's password to restic on its own and the
// rest to restic as the backend's
export function buildNixieBackupEnv(
  secrets: NixieBackupInputs['secrets'],
): Record<string, Output<string> | string> {
  return {
    NIXIE_BACKUP_DATA_REPOSITORY: secrets.dataRepository,
    NIXIE_BACKUP_DATA_PASSWORD: secrets.dataPassword,
    NIXIE_BACKUP_KEY_REPOSITORY: secrets.keyRepository,
    NIXIE_BACKUP_KEY_PASSWORD: secrets.keyPassword,
    AWS_ACCESS_KEY_ID: secrets.accessKeyID,
    AWS_SECRET_ACCESS_KEY: secrets.secretAccessKey,
    AWS_DEFAULT_REGION: 'auto',
  };
}

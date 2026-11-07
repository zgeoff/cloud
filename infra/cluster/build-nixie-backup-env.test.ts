import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildNixieBackupEnv } from './build-nixie-backup-env.ts';

test("it names each repo and its password with the nixie-backup job's variables, beside R2's", () => {
  const secrets = {
    dataRepository: output(
      's3:https://0123456789abcdef.r2.cloudflarestorage.com/nixie-backups/nixie',
    ),
    dataPassword: output('d'.repeat(32)),
    keyRepository: output(
      's3:https://0123456789abcdef.r2.cloudflarestorage.com/nixie-backups/nixie-keys',
    ),
    keyPassword: output('k'.repeat(32)),
    accessKeyID: output('a'.repeat(32)),
    secretAccessKey: output('s'.repeat(64)),
  };

  expect(buildNixieBackupEnv(secrets)).toStrictEqual({
    NIXIE_BACKUP_DATA_REPOSITORY: secrets.dataRepository,
    NIXIE_BACKUP_DATA_PASSWORD: secrets.dataPassword,
    NIXIE_BACKUP_KEY_REPOSITORY: secrets.keyRepository,
    NIXIE_BACKUP_KEY_PASSWORD: secrets.keyPassword,
    AWS_ACCESS_KEY_ID: secrets.accessKeyID,
    AWS_SECRET_ACCESS_KEY: secrets.secretAccessKey,
    AWS_DEFAULT_REGION: 'auto',
  });
});

import { readFileSync } from 'node:fs';
import type { Provider } from '@pulumi/kubernetes';
import { CronJob } from '@pulumi/kubernetes/batch/v1';
import { ConfigMap, Secret } from '@pulumi/kubernetes/core/v1';
import type { Output } from '@pulumi/pulumi';
import type { PepysBackupInputs } from '../inputs/index.ts';
import { pepysImages } from '../shared/pepys-images.ts';
import { pepysWorkloads } from '../shared/pepys-workloads.ts';
import { buildPepysBackupPodSpec } from './build-pepys-backup-pod-spec.ts';

export function createPepysBackupJob(
  cluster: Provider,
  namespace: Output<string>,
  backup: PepysBackupInputs,
): CronJob {
  // Pulumi names both, so a changed key or script replaces it and the next run reads the new one
  const env = new Secret(
    'pepys-backup',
    {
      metadata: { namespace },
      stringData: {
        RCLONE_CONFIG_GARAGE_ACCESS_KEY_ID: backup.secrets.garageAccessKeyID,
        RCLONE_CONFIG_GARAGE_SECRET_ACCESS_KEY: backup.secrets.garageSecretAccessKey,
        RCLONE_CONFIG_R2_ENDPOINT: backup.secrets.r2Endpoint,
        RCLONE_CONFIG_R2_ACCESS_KEY_ID: backup.secrets.r2AccessKeyID,
        RCLONE_CONFIG_R2_SECRET_ACCESS_KEY: backup.secrets.r2SecretAccessKey,
        PEPYS_BACKUP_BUCKET: backup.secrets.r2Bucket,
      },
    },
    { provider: cluster },
  );

  const script = new ConfigMap(
    'pepys-backup-script',
    {
      metadata: { namespace },
      data: {
        'backup.sh': readFileSync(
          new URL('../../deploy/pepys/backup/backup.sh', import.meta.url),
          'utf8',
        ),
      },
    },
    { provider: cluster },
  );

  return new CronJob(
    pepysWorkloads.backup.name,
    {
      metadata: { name: pepysWorkloads.backup.name, namespace },
      spec: {
        // after the files backup at 04:30, so the two never share the node's disk
        schedule: '0 5 * * *',
        timeZone: 'Australia/Melbourne',
        suspend: false,
        concurrencyPolicy: 'Forbid',
        jobTemplate: {
          spec: {
            backoffLimit: 2,
            template: {
              metadata: { labels: pepysWorkloads.backup.labels },
              spec: buildPepysBackupPodSpec({
                image: pepysImages.rcloneImage,
                scriptConfigMap: script.metadata.name,
                envSecret: env.metadata.name,
              }),
            },
          },
        },
      },
    },
    { provider: cluster },
  );
}

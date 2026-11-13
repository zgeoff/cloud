import type { input } from '@pulumi/kubernetes/types';
import type { Output } from '@pulumi/pulumi';
import { pepysWorkloads } from '../shared/pepys-workloads.ts';
import { buildPepysBackupPodSpec } from './build-pepys-backup-pod-spec.ts';

interface PepysBackupCronJobInputs {
  readonly image: string;
  readonly scriptConfigMap: Output<string>;
  readonly envSecret: Output<string>;
}

export function buildPepysBackupCronJobSpec(
  inputs: PepysBackupCronJobInputs,
): input.batch.v1.CronJobSpec {
  return {
    // 14:00 or 15:00 in Melbourne, hours away from the nightly backups of the other workloads
    schedule: '0 4 * * *',
    timeZone: 'Etc/UTC',
    suspend: false,
    concurrencyPolicy: 'Forbid',
    jobTemplate: {
      spec: {
        backoffLimit: 2,
        template: {
          metadata: { labels: pepysWorkloads.backup.labels },
          spec: buildPepysBackupPodSpec(inputs),
        },
      },
    },
  };
}

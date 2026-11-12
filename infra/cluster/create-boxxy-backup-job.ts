import type { Provider } from '@pulumi/kubernetes';
import type { StatefulSet } from '@pulumi/kubernetes/apps/v1';
import { CronJob } from '@pulumi/kubernetes/batch/v1';
import { Secret } from '@pulumi/kubernetes/core/v1';
import type { Output } from '@pulumi/pulumi';
import type { BoxxyBackupInputs } from '../inputs/index.ts';
import { buildATCGatewayBackupPodSpec } from './build-atc-gateway-backup-pod-spec.ts';
import { ghcrPullSecretName } from './build-ghcr-pull-secret-args.ts';

interface BoxxyBackupJobInputs {
  readonly namespace: Output<string>;

  // the boxxy StatefulSet, whose first pod owns the claim the backup reads
  readonly statefulSet: StatefulSet;
  readonly backup: BoxxyBackupInputs;
}

// The atc gateway's backup image backs up every *.db in its state folder with sqlite3 .backup, so
// its own entrypoint backs up the boxxy store as it is.
export function createBoxxyBackupJob(cluster: Provider, inputs: BoxxyBackupJobInputs): CronJob {
  const env = new Secret(
    'boxxy-backup',
    {
      // a fixed name, because deploy/boxxy/restore-job.yaml names it
      metadata: { name: 'boxxy-backup', namespace: inputs.namespace },
      stringData: {
        RESTIC_REPOSITORY: inputs.backup.secrets.repository,
        RESTIC_PASSWORD: inputs.backup.secrets.password,
        AWS_ACCESS_KEY_ID: inputs.backup.secrets.accessKeyID,
        AWS_SECRET_ACCESS_KEY: inputs.backup.secrets.secretAccessKey,
        AWS_DEFAULT_REGION: 'auto',
      },
    },
    { provider: cluster },
  );

  return new CronJob(
    'boxxy-backup',
    {
      metadata: { name: 'boxxy-backup', namespace: inputs.namespace },
      spec: {
        // half an hour after the files backup, so no two backups share the node's disk
        schedule: '0 5 * * *',
        timeZone: 'Australia/Melbourne',
        suspend: false,
        concurrencyPolicy: 'Forbid',
        jobTemplate: {
          spec: {
            backoffLimit: 2,
            template: {
              spec: buildATCGatewayBackupPodSpec({
                image: inputs.backup.image,

                // one node, so ReadWriteOnce allows the claim beside the server; sqlite3 .backup
                // stays consistent while the server writes
                claim: 'data-boxxy-0',
                envSecret: 'boxxy-backup',
                pullSecret: ghcrPullSecretName,
              }),
            },
          },
        },
      },
    },
    { provider: cluster, dependsOn: [env, inputs.statefulSet] },
  );
}

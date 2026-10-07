import type { Provider } from '@pulumi/kubernetes';
import { CronJob } from '@pulumi/kubernetes/batch/v1';
import { Secret } from '@pulumi/kubernetes/core/v1';
import type { Output } from '@pulumi/pulumi';
import type { ATCGatewayBackupSecrets } from './atc-gateway.ts';
import { buildATCGatewayBackupPodSpec } from './build-atc-gateway-backup-pod-spec.ts';

interface BackupJobInputs {
  readonly namespace: Output<string>;
  readonly claim: Output<string>;
  readonly image: string;
  readonly secrets: ATCGatewayBackupSecrets;
}

// Nightly restic backup of the gateway's SQLite files to R2. It mounts the claim
// next to the gateway (one node, so ReadWriteOnce allows it) and copies each
// database with sqlite3 .backup, which is consistent while the gateway writes.
export function createATCGatewayBackupJob(cluster: Provider, inputs: BackupJobInputs): CronJob {
  const env = new Secret(
    'atc-gateway-backup',
    {
      metadata: { name: 'atc-gateway-backup', namespace: inputs.namespace },
      stringData: {
        RESTIC_REPOSITORY: inputs.secrets.repository,
        RESTIC_PASSWORD: inputs.secrets.password,
        AWS_ACCESS_KEY_ID: inputs.secrets.accessKeyID,
        AWS_SECRET_ACCESS_KEY: inputs.secrets.secretAccessKey,
        AWS_DEFAULT_REGION: 'auto',
      },
    },
    { provider: cluster },
  );

  return new CronJob(
    'atc-gateway-backup',
    {
      metadata: { name: 'atc-gateway-backup', namespace: inputs.namespace },
      spec: {
        schedule: '30 3 * * *',
        timeZone: 'Australia/Melbourne',
        suspend: false,
        concurrencyPolicy: 'Forbid',
        jobTemplate: {
          spec: {
            backoffLimit: 2,
            template: {
              spec: buildATCGatewayBackupPodSpec({
                image: inputs.image,
                claim: inputs.claim,
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

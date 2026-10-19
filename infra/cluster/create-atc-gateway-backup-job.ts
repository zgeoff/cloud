import type { Provider } from '@pulumi/kubernetes';
import { CronJob } from '@pulumi/kubernetes/batch/v1';
import { Secret } from '@pulumi/kubernetes/core/v1';
import type { Output } from '@pulumi/pulumi';
import type { ATCGatewayBackupSecrets } from '../inputs/index.ts';
import { buildATCGatewayBackupPodSpec } from './build-atc-gateway-backup-pod-spec.ts';

interface BackupJobInputs {
  readonly namespace: Output<string>;
  readonly claim: Output<string>;
  readonly image: string;
  readonly pullSecret: Output<string>;
  readonly secrets: ATCGatewayBackupSecrets;
}

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

                // One node, so ReadWriteOnce lets the backup mount the claim beside the gateway;
                // sqlite3 .backup stays consistent while the gateway writes.
                claim: inputs.claim,
                envSecret: env.metadata.name,
                pullSecret: inputs.pullSecret,
              }),
            },
          },
        },
      },
    },
    { provider: cluster },
  );
}

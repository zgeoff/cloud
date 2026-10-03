import type { Provider } from '@pulumi/kubernetes';
import { CronJob } from '@pulumi/kubernetes/batch/v1';
import { Secret } from '@pulumi/kubernetes/core/v1';
import type { input } from '@pulumi/kubernetes/types';
import type { Output } from '@pulumi/pulumi';
import type { ATCGatewayBackupSecrets } from './atc-gateway.ts';
import { buildATCPodSecurity } from './build-atc-gateway-spec.ts';

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

        // Suspended: backups run only as manual Jobs from this template until Geoff
        // approves the nightly schedule. Flipping this starts recurring R2 writes.
        suspend: true,
        concurrencyPolicy: 'Forbid',
        jobTemplate: {
          spec: {
            backoffLimit: 2,
            template: { spec: buildBackupPodSpec(inputs, env.metadata.name) },
          },
        },
      },
    },
    { provider: cluster },
  );
}

function buildBackupPodSpec(
  inputs: BackupJobInputs,
  envSecret: Output<string>,
): input.core.v1.PodSpec {
  return {
    restartPolicy: 'OnFailure',
    securityContext: buildATCPodSecurity(),
    automountServiceAccountToken: false,
    containers: [
      {
        name: 'backup',
        image: inputs.image,
        args: ['backup'],
        env: [
          { name: 'STATE_DIR', value: '/state' },
          { name: 'HOME', value: '/tmp' },
        ],
        envFrom: [{ secretRef: { name: envSecret } }],
        volumeMounts: [
          { name: 'state', mountPath: '/state' },
          { name: 'tmp', mountPath: '/tmp' },
        ],
        resources: { requests: { cpu: '50m', memory: '64Mi' }, limits: { memory: '256Mi' } },
        securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: ['ALL'] } },
      },
    ],
    volumes: [
      { name: 'state', persistentVolumeClaim: { claimName: inputs.claim } },
      { name: 'tmp', emptyDir: {} },
    ],
  };
}

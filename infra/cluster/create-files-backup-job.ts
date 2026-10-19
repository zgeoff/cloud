import { readFileSync } from 'node:fs';
import type { Provider } from '@pulumi/kubernetes';
import type { StatefulSet } from '@pulumi/kubernetes/apps/v1';
import { CronJob } from '@pulumi/kubernetes/batch/v1';
import { ConfigMap, Secret } from '@pulumi/kubernetes/core/v1';
import type { Output } from '@pulumi/pulumi';
import type { FilesBackupInputs } from '../inputs/index.ts';
import { buildFilesBackupPodSpec } from './build-files-backup-pod-spec.ts';
import { ghcrPullSecretName } from './build-ghcr-pull-secret-args.ts';

interface FilesBackupJobInputs {
  readonly namespace: Output<string>;

  // the files StatefulSet, whose first pod owns the claim the backup reads
  readonly statefulSet: StatefulSet;
  readonly backup: FilesBackupInputs;
}

// Nightly restic backup of the files service's volume to R2, from its claim beside the service (one
// node, so ReadWriteOnce allows it). The Secret and the ConfigMap keep fixed names, because
// deploy/files/restore-job.yaml names them; the namespace's pull Secret pulls the backup image too.
export function createFilesBackupJob(cluster: Provider, inputs: FilesBackupJobInputs): CronJob {
  const env = createEnvSecret(cluster, inputs);
  const script = createScriptConfigMap(cluster, inputs.namespace);

  return new CronJob(
    'files-backup',
    {
      metadata: { name: 'files-backup', namespace: inputs.namespace },
      spec: {
        // half an hour after nixie's backup, so the two never share the node's disk
        schedule: '30 4 * * *',
        timeZone: 'Australia/Melbourne',
        suspend: false,
        concurrencyPolicy: 'Forbid',
        jobTemplate: {
          spec: {
            backoffLimit: 2,
            template: {
              spec: buildFilesBackupPodSpec({
                image: inputs.backup.image,
                claim: 'data-files-0',
                scriptConfigMap: 'files-backup-script',
                envSecret: 'files-backup',
                pullSecret: ghcrPullSecretName,
              }),
            },
          },
        },
      },
    },
    { provider: cluster, dependsOn: [env, script, inputs.statefulSet] },
  );
}

function createEnvSecret(cluster: Provider, inputs: FilesBackupJobInputs): Secret {
  return new Secret(
    'files-backup',
    {
      metadata: { name: 'files-backup', namespace: inputs.namespace },
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
}

// Pulumi updates the script in place, and the CronJob's next run reads it
function createScriptConfigMap(cluster: Provider, namespace: Output<string>): ConfigMap {
  return new ConfigMap(
    'files-backup-script',
    {
      metadata: { name: 'files-backup-script', namespace },
      data: {
        'backup.sh': readFileSync(
          new URL('../../deploy/files/backup/backup.sh', import.meta.url),
          'utf8',
        ),
      },
    },
    { provider: cluster },
  );
}

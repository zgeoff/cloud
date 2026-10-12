import { readFileSync } from 'node:fs';
import type { Provider } from '@pulumi/kubernetes';
import type { StatefulSet } from '@pulumi/kubernetes/apps/v1';
import { CronJob } from '@pulumi/kubernetes/batch/v1';
import { ConfigMap, Secret } from '@pulumi/kubernetes/core/v1';
import type { Output } from '@pulumi/pulumi';
import { buildNixieBackupPodSpec } from './build-nixie-backup-pod-spec.ts';
import type { NixieBackupInputs } from './nixie.ts';

interface NixieBackupJobInputs {
  readonly namespace: Output<string>;

  // nixie's StatefulSet, whose first pod owns the claim the backup reads
  readonly statefulSet: StatefulSet;
  readonly backup: NixieBackupInputs;
}

// Nightly restic backup of nixie.db and keys.db to R2, from nixie's claim beside nixie (one node,
// so ReadWriteOnce allows it). The Secret and the ConfigMap keep fixed names, unlike nixie's own,
// because deploy/nixie/restore-job.yaml names them.
export function createNixieBackupJob(cluster: Provider, inputs: NixieBackupJobInputs): CronJob {
  const env = createEnvSecret(cluster, inputs);
  const script = createScriptConfigMap(cluster, inputs.namespace);

  return new CronJob(
    'nixie-backup',
    {
      metadata: { name: 'nixie-backup', namespace: inputs.namespace },
      spec: {
        // half an hour after the atc gateway's backup, so the two never share the node's disk
        schedule: '0 4 * * *',
        timeZone: 'Australia/Melbourne',
        suspend: false,
        concurrencyPolicy: 'Forbid',
        jobTemplate: {
          spec: {
            backoffLimit: 2,
            template: {
              spec: buildNixieBackupPodSpec({
                image: inputs.backup.image,
                claim: 'data-nixie-0',
                scriptConfigMap: 'nixie-backup-script',
                envSecret: 'nixie-backup',
              }),
            },
          },
        },
      },
    },
    { provider: cluster, dependsOn: [env, script, inputs.statefulSet] },
  );
}

function createEnvSecret(cluster: Provider, inputs: NixieBackupJobInputs): Secret {
  return new Secret(
    'nixie-backup',
    {
      metadata: { name: 'nixie-backup', namespace: inputs.namespace },
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
    'nixie-backup-script',
    {
      metadata: { name: 'nixie-backup-script', namespace },
      data: {
        'backup.sh': readFileSync(
          new URL('../deploy/nixie/backup/backup.sh', import.meta.url),
          'utf8',
        ),
      },
    },
    { provider: cluster },
  );
}

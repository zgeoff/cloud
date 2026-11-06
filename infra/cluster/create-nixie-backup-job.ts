import { readFileSync } from 'node:fs';
import type { Provider } from '@pulumi/kubernetes';
import type { StatefulSet } from '@pulumi/kubernetes/apps/v1';
import { CronJob } from '@pulumi/kubernetes/batch/v1';
import { ConfigMap, Secret } from '@pulumi/kubernetes/core/v1';
import type { Output } from '@pulumi/pulumi';
import type { NixieBackupInputs } from '../inputs/index.ts';
import { ghcrPullSecretName } from './build-ghcr-pull-secret-args.ts';
import { buildNixieBackupEnv } from './build-nixie-backup-env.ts';
import { buildNixieBackupPodSpec } from './build-nixie-backup-pod-spec.ts';
import { nixieConfigKey } from './build-nixie-spec.ts';
import { createGHCRPullSecret } from './create-ghcr-pull-secret.ts';

interface NixieBackupJobInputs {
  readonly namespace: Output<string>;
  readonly statefulSet: StatefulSet;

  // the rendered config of the running nixie, which the restore Job's `nixie restore` reads
  readonly config: string;

  readonly backup: NixieBackupInputs;
}

// the CronJob mounts neither ConfigMap: only the restore Job, whose YAML names them, reads them
export function createNixieBackupJob(cluster: Provider, inputs: NixieBackupJobInputs): CronJob {
  const env = createEnvSecret(cluster, inputs);

  createScriptConfigMap(cluster, inputs.namespace);
  createConfigMap(cluster, inputs);

  const pull = createGHCRPullSecret(cluster, {
    resourceName: 'nixie-ghcr-pull',
    namespace: inputs.namespace,
    credential: inputs.backup.pullCredential,
  });

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

                // one node, so ReadWriteOnce allows the claim beside nixie
                claim: 'data-nixie-0',

                // a fixed name, unlike nixie's own Secret, because the restore Job's YAML names it
                envSecret: 'nixie-backup',
                pullSecret: ghcrPullSecretName,
              }),
            },
          },
        },
      },
    },
    { provider: cluster, dependsOn: [env, pull, inputs.statefulSet] },
  );
}

function createEnvSecret(cluster: Provider, inputs: NixieBackupJobInputs): Secret {
  return new Secret(
    'nixie-backup',
    {
      metadata: { name: 'nixie-backup', namespace: inputs.namespace },
      stringData: buildNixieBackupEnv(inputs.backup.secrets),
    },

    // as on the script ConfigMap: a change to its data replaces it under the same name
    { provider: cluster, deleteBeforeReplace: true },
  );
}

function createScriptConfigMap(cluster: Provider, namespace: Output<string>): ConfigMap {
  return new ConfigMap(
    'nixie-backup-script',
    {
      // a fixed name, because the restore Job's YAML names it
      metadata: { name: 'nixie-backup-script', namespace },
      data: {
        'restore.sh': readFileSync(
          new URL('../../deploy/nixie/backup/restore.sh', import.meta.url),
          'utf8',
        ),
      },
    },

    // Pulumi replaces a ConfigMap whose data changes, and a create under the same name fails while
    // the old one exists
    { provider: cluster, deleteBeforeReplace: true },
  );
}

function createConfigMap(cluster: Provider, inputs: NixieBackupJobInputs): ConfigMap {
  return new ConfigMap(
    'nixie-backup-config',
    {
      // a fixed name, as on the script, because the restore Job's YAML names it
      metadata: { name: 'nixie-backup-config', namespace: inputs.namespace },
      data: { [nixieConfigKey]: inputs.config },
    },

    // as on the script: each change to config.yaml replaces it
    { provider: cluster, deleteBeforeReplace: true },
  );
}

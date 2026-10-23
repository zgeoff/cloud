import { readFileSync } from 'node:fs';
import type { Provider } from '@pulumi/kubernetes';
import type { StatefulSet } from '@pulumi/kubernetes/apps/v1';
import { CronJob } from '@pulumi/kubernetes/batch/v1';
import { ConfigMap, Secret } from '@pulumi/kubernetes/core/v1';
import type { Output } from '@pulumi/pulumi';
import type { NixieBackupInputs } from '../inputs/index.ts';
import { ghcrPullSecretName } from './build-ghcr-pull-secret-args.ts';
import { buildNixieBackupPodSpec } from './build-nixie-backup-pod-spec.ts';
import { nixieConfigKey } from './build-nixie-spec.ts';
import { createGHCRPullSecret } from './create-ghcr-pull-secret.ts';

interface NixieBackupJobInputs {
  readonly namespace: Output<string>;
  readonly statefulSet: StatefulSet;

  // the image and the rendered config of the running nixie, whose backup command copies its data
  readonly nixieImage: string;
  readonly config: string;

  readonly backup: NixieBackupInputs;
}

export function createNixieBackupJob(cluster: Provider, inputs: NixieBackupJobInputs): CronJob {
  const env = createEnvSecret(cluster, inputs);
  const script = createScriptConfigMap(cluster, inputs.namespace);
  const config = createConfigMap(cluster, inputs);

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
                nixieImage: inputs.nixieImage,

                // one node, so ReadWriteOnce allows the claim beside nixie
                claim: 'data-nixie-0',

                // fixed names, unlike nixie's own, because the restore Job's YAML names them
                scriptConfigMap: 'nixie-backup-script',
                configMap: 'nixie-backup-config',
                envSecret: 'nixie-backup',
                pullSecret: ghcrPullSecretName,
              }),
            },
          },
        },
      },
    },
    { provider: cluster, dependsOn: [env, script, config, pull, inputs.statefulSet] },
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

function createScriptConfigMap(cluster: Provider, namespace: Output<string>): ConfigMap {
  return new ConfigMap(
    'nixie-backup-script',
    {
      // Pulumi updates the script in place, and the CronJob's next run reads it
      metadata: { name: 'nixie-backup-script', namespace },
      data: {
        'backup.sh': readFileSync(
          new URL('../../deploy/nixie/backup/backup.sh', import.meta.url),
          'utf8',
        ),
      },
    },
    { provider: cluster },
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
    { provider: cluster },
  );
}

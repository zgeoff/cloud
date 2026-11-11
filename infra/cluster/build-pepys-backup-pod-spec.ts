import type { input } from '@pulumi/kubernetes/types';
import type { Output } from '@pulumi/pulumi';
import { buildPepysContainerSecurity } from './build-pepys-container-security.ts';
import { buildPepysPodSecurity } from './build-pepys-pod-security.ts';
import { pepysWorkloads } from './pepys-workloads.ts';

interface PepysBackupPodInputs {
  readonly image: string;

  // the ConfigMap that holds deploy/pepys/backup/backup.sh
  readonly scriptConfigMap: Output<string>;

  // the Secret with the two remotes' keys, R2's endpoint and PEPYS_BACKUP_BUCKET
  readonly envSecret: Output<string>;
}

export function buildPepysBackupPodSpec(inputs: PepysBackupPodInputs) {
  return {
    restartPolicy: 'OnFailure',
    ...buildPepysPodSecurity(),
    containers: [
      {
        name: 'backup',
        image: inputs.image,
        command: ['/bin/sh', '/opt/pepys-backup/backup.sh', ...pepysWorkloads.backup.buckets],
        env: [
          { name: 'HOME', value: '/tmp' },
          { name: 'RCLONE_CONFIG_GARAGE_TYPE', value: 's3' },
          { name: 'RCLONE_CONFIG_GARAGE_PROVIDER', value: 'Other' },
          { name: 'RCLONE_CONFIG_GARAGE_ENDPOINT', value: pepysWorkloads.garage.url },
          { name: 'RCLONE_CONFIG_GARAGE_REGION', value: 'garage' },
          { name: 'RCLONE_CONFIG_R2_TYPE', value: 's3' },
          { name: 'RCLONE_CONFIG_R2_PROVIDER', value: 'Cloudflare' },
        ],
        envFrom: [{ secretRef: { name: inputs.envSecret } }],
        volumeMounts: [
          { name: 'script', mountPath: '/opt/pepys-backup', readOnly: true },
          { name: 'tmp', mountPath: '/tmp' },
        ],
        resources: { requests: { cpu: '50m', memory: '64Mi' }, limits: { memory: '256Mi' } },
        securityContext: buildPepysContainerSecurity(),
      },
    ],
    volumes: [
      { name: 'script', configMap: { name: inputs.scriptConfigMap } },
      { name: 'tmp', emptyDir: {} },
    ],
  } satisfies input.core.v1.PodSpec;
}

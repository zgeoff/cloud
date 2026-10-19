import type { input } from '@pulumi/kubernetes/types';

interface FilesBackupPodInputs {
  // the image with restic and sqlite3 that runs the script
  readonly image: string;

  // the files service's data claim, mounted at STATE_DIR
  readonly claim: string;

  // the ConfigMap that holds deploy/files/backup/backup.sh
  readonly scriptConfigMap: string;

  // the Secret with restic's and R2's environment
  readonly envSecret: string;

  // the dockerconfigjson Secret that pulls the private backup image
  readonly pullSecret: string;
}

// The backup Job's pod: deploy/files/backup/backup.sh's `backup`, run in the backup image with the
// files service's claim at /state, as the service's own user, so a restore leaves files the service
// can open. The command replaces the image's own entrypoint, which backs up the atc gateway.
export function buildFilesBackupPodSpec(inputs: FilesBackupPodInputs) {
  return {
    restartPolicy: 'OnFailure',
    securityContext: {
      runAsNonRoot: true,
      runAsUser: 65_532,
      runAsGroup: 65_532,
      fsGroup: 65_532,
      seccompProfile: { type: 'RuntimeDefault' },
    },
    automountServiceAccountToken: false,
    imagePullSecrets: [{ name: inputs.pullSecret }],
    containers: [
      {
        name: 'backup',
        image: inputs.image,
        command: ['/bin/sh', '/opt/files-backup/backup.sh'],
        args: ['backup'],
        env: [
          { name: 'STATE_DIR', value: '/state' },
          { name: 'HOME', value: '/tmp' },
        ],
        envFrom: [{ secretRef: { name: inputs.envSecret } }],
        volumeMounts: [
          { name: 'state', mountPath: '/state' },
          { name: 'script', mountPath: '/opt/files-backup', readOnly: true },
          { name: 'tmp', mountPath: '/tmp' },
        ],
        resources: { requests: { cpu: '50m', memory: '64Mi' }, limits: { memory: '256Mi' } },
        securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: ['ALL'] } },
      },
    ],
    volumes: [
      { name: 'state', persistentVolumeClaim: { claimName: inputs.claim } },
      { name: 'script', configMap: { name: inputs.scriptConfigMap } },
      { name: 'tmp', emptyDir: {} },
    ],
  } satisfies input.core.v1.PodSpec;
}

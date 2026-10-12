import type { input } from '@pulumi/kubernetes/types';

interface NixieBackupPodInputs {
  // the image with restic and sqlite3 that runs the script
  readonly image: string;

  // nixie's data claim, mounted at STATE_DIR
  readonly claim: string;

  // the ConfigMap that holds deploy/nixie/backup/backup.sh
  readonly scriptConfigMap: string;

  // the Secret with restic's and R2's environment
  readonly envSecret: string;
}

// The backup Job's pod: deploy/nixie/backup/backup.sh's `backup`, run in the backup image with
// nixie's claim at /state, as nixie's own user, so a restore leaves files nixie can open. The
// command replaces the image's own entrypoint, which backs up the atc gateway.
export function buildNixieBackupPodSpec(inputs: NixieBackupPodInputs): input.core.v1.PodSpec {
  return {
    restartPolicy: 'OnFailure',
    securityContext: {
      runAsNonRoot: true,
      runAsUser: 10_001,
      runAsGroup: 10_001,
      fsGroup: 10_001,
      seccompProfile: { type: 'RuntimeDefault' },
    },
    automountServiceAccountToken: false,
    containers: [
      {
        name: 'backup',
        image: inputs.image,
        command: ['/bin/sh', '/opt/nixie-backup/backup.sh'],
        args: ['backup'],
        env: [
          { name: 'STATE_DIR', value: '/state' },
          { name: 'HOME', value: '/tmp' },
        ],
        envFrom: [{ secretRef: { name: inputs.envSecret } }],
        volumeMounts: [
          { name: 'state', mountPath: '/state' },
          { name: 'script', mountPath: '/opt/nixie-backup', readOnly: true },
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
  };
}

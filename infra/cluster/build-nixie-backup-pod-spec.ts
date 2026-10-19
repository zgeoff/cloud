import type { input } from '@pulumi/kubernetes/types';

interface NixieBackupPodInputs {
  readonly image: string;
  readonly claim: string;
  readonly scriptConfigMap: string;
  readonly envSecret: string;
  readonly pullSecret: string;
}

export function buildNixieBackupPodSpec(inputs: NixieBackupPodInputs) {
  return {
    restartPolicy: 'OnFailure',

    // nixie's own user, so a restore leaves files nixie can open
    securityContext: {
      runAsNonRoot: true,
      runAsUser: 10_001,
      runAsGroup: 10_001,
      fsGroup: 10_001,
      seccompProfile: { type: 'RuntimeDefault' },
    },
    automountServiceAccountToken: false,
    imagePullSecrets: [{ name: inputs.pullSecret }],
    containers: [
      {
        name: 'backup',
        image: inputs.image,

        // the image's own entrypoint backs up the atc gateway
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
  } satisfies input.core.v1.PodSpec;
}

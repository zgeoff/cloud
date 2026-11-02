import type { input } from '@pulumi/kubernetes/types';

interface NixieRestorePodInputs {
  readonly image: string;
  readonly nixieImage: string;
  readonly claim: string;
  readonly scriptConfigMap: string;
  readonly configMap: string;
  readonly envSecret: string;
  readonly pullSecret: string;
}

// The backup pod in reverse: restic restores a snapshot into /tmp, and nixie's own restore command
// replaces its databases with it, so restic never mounts nixie's volume.
export function buildNixieRestorePodSpec(inputs: NixieRestorePodInputs) {
  return {
    restartPolicy: 'Never',

    // nixie's own user, so the restored files are nixie's
    securityContext: {
      runAsNonRoot: true,
      runAsUser: 10_001,
      runAsGroup: 10_001,
      fsGroup: 10_001,
      seccompProfile: { type: 'RuntimeDefault' },
    },
    automountServiceAccountToken: false,
    imagePullSecrets: [{ name: inputs.pullSecret }],
    initContainers: [
      {
        name: 'fetch',
        image: inputs.image,
        command: ['/bin/sh', '/opt/nixie-backup/backup.sh'],
        args: ['restore'],
        env: [
          { name: 'HOME', value: '/tmp' },
          { name: 'SNAPSHOT', value: 'latest' },
        ],
        envFrom: [{ secretRef: { name: inputs.envSecret } }],
        volumeMounts: [
          { name: 'script', mountPath: '/opt/nixie-backup', readOnly: true },
          { name: 'tmp', mountPath: '/tmp' },
        ],
        securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: ['ALL'] } },
      },
    ],
    containers: [
      {
        name: 'restore',
        image: inputs.nixieImage,
        command: ['nixie', 'restore', '--from', '/tmp/nixie-backup', '--yes'],
        volumeMounts: [
          { name: 'state', mountPath: '/data' },
          {
            name: 'config',
            mountPath: '/etc/nixie/config.yaml',
            subPath: 'config.yaml',
            readOnly: true,
          },
          { name: 'tmp', mountPath: '/tmp' },
        ],
        securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: ['ALL'] } },
      },
    ],
    volumes: [
      { name: 'state', persistentVolumeClaim: { claimName: inputs.claim } },
      { name: 'config', configMap: { name: inputs.configMap } },
      { name: 'script', configMap: { name: inputs.scriptConfigMap } },
      { name: 'tmp', emptyDir: {} },
    ],
  } satisfies input.core.v1.PodSpec;
}

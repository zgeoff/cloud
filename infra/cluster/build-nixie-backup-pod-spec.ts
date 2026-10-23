import type { input } from '@pulumi/kubernetes/types';

interface NixieBackupPodInputs {
  readonly image: string;
  readonly nixieImage: string;
  readonly claim: string;
  readonly scriptConfigMap: string;
  readonly configMap: string;
  readonly envSecret: string;
  readonly pullSecret: string;
}

// Only nixie's own backup command reads nixie's databases (nixie's
// docs/architecture/deployment/host-commands.md), so restic uploads the copy it leaves in /tmp and
// never mounts nixie's volume.
export function buildNixieBackupPodSpec(inputs: NixieBackupPodInputs) {
  return {
    restartPolicy: 'OnFailure',

    // nixie's own user, so nixie's command opens its files
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
        name: 'copy',
        image: inputs.nixieImage,
        command: ['nixie', 'backup', '--to', '/tmp/nixie-backup'],
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
        resources: { requests: { cpu: '50m', memory: '128Mi' }, limits: { memory: '512Mi' } },
        securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: ['ALL'] } },
      },
    ],
    containers: [
      {
        name: 'backup',
        image: inputs.image,

        // the image's own entrypoint backs up the atc gateway
        command: ['/bin/sh', '/opt/nixie-backup/backup.sh'],
        args: ['backup'],
        env: [{ name: 'HOME', value: '/tmp' }],
        envFrom: [{ secretRef: { name: inputs.envSecret } }],
        volumeMounts: [
          { name: 'script', mountPath: '/opt/nixie-backup', readOnly: true },
          { name: 'tmp', mountPath: '/tmp' },
        ],
        resources: { requests: { cpu: '50m', memory: '64Mi' }, limits: { memory: '256Mi' } },
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

import type { input } from '@pulumi/kubernetes/types';

interface NixieBackupPodInputs {
  readonly image: string;
  readonly claim: string;
  readonly envSecret: string;
  readonly pullSecret: string;
}

// nixie stages its backup sets in this folder of its data volume
const stagingFolder = 'backup';

// The kubelet creates a missing subPath as root, which nixie's user cannot write, so an init
// container with no credentials creates the staging folder first, as nixie's user.
export function buildNixieBackupPodSpec(inputs: NixieBackupPodInputs) {
  return {
    restartPolicy: 'OnFailure',

    // nixie's own user, so nixie can remove the receipts and copies the job leaves
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
        name: 'staging',
        image: inputs.image,
        command: ['mkdir', '-p', '-m', '0700', `/state/${stagingFolder}`],
        volumeMounts: [{ name: 'state', mountPath: '/state' }],
        resources: { requests: { cpu: '10m', memory: '16Mi' }, limits: { memory: '32Mi' } },
        securityContext: {
          allowPrivilegeEscalation: false,
          readOnlyRootFilesystem: true,
          capabilities: { drop: ['ALL'] },
        },
      },
    ],
    containers: [
      {
        name: 'backup',
        image: inputs.image,
        args: ['run'],
        env: [
          { name: 'NIXIE_BACKUP_STAGING_DIR', value: '/backup' },
          { name: 'HOME', value: '/tmp' },
        ],
        envFrom: [{ secretRef: { name: inputs.envSecret } }],
        volumeMounts: [
          { name: 'state', mountPath: '/backup', subPath: stagingFolder },
          { name: 'tmp', mountPath: '/tmp' },
        ],

        // restic's prune holds the repo's index in memory
        resources: { requests: { cpu: '50m', memory: '128Mi' }, limits: { memory: '512Mi' } },
        securityContext: {
          allowPrivilegeEscalation: false,
          readOnlyRootFilesystem: true,
          capabilities: { drop: ['ALL'] },
        },
      },
    ],
    volumes: [
      { name: 'state', persistentVolumeClaim: { claimName: inputs.claim } },
      { name: 'tmp', emptyDir: {} },
    ],
  } satisfies input.core.v1.PodSpec;
}

import type { input } from '@pulumi/kubernetes/types';
import type { Output } from '@pulumi/pulumi';
import { buildATCPodSecurity } from './build-atc-gateway-spec.ts';

interface BackupPodInputs {
  readonly image: string;

  // the gateway's state claim, mounted at STATE_DIR
  readonly claim: Output<string>;

  // the Secret with restic's and R2's environment
  readonly envSecret: Output<string>;
}

// The backup Job's pod: the backup image's `backup` with the gateway's claim at
// /state, as the gateway's own non-root user
export function buildATCGatewayBackupPodSpec(inputs: BackupPodInputs): input.core.v1.PodSpec {
  return {
    restartPolicy: 'OnFailure',
    securityContext: buildATCPodSecurity(),
    automountServiceAccountToken: false,
    containers: [
      {
        name: 'backup',
        image: inputs.image,
        args: ['backup'],
        env: [
          { name: 'STATE_DIR', value: '/state' },
          { name: 'HOME', value: '/tmp' },
        ],
        envFrom: [{ secretRef: { name: inputs.envSecret } }],
        volumeMounts: [
          { name: 'state', mountPath: '/state' },
          { name: 'tmp', mountPath: '/tmp' },
        ],
        resources: { requests: { cpu: '50m', memory: '64Mi' }, limits: { memory: '256Mi' } },
        securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: ['ALL'] } },
      },
    ],
    volumes: [
      { name: 'state', persistentVolumeClaim: { claimName: inputs.claim } },
      { name: 'tmp', emptyDir: {} },
    ],
  };
}

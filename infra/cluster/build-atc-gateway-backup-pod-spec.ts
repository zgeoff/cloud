import type { input } from '@pulumi/kubernetes/types';
import type { Input } from '@pulumi/pulumi';
import { buildATCPodSecurity } from './build-atc-gateway-spec.ts';

interface BackupPodInputs {
  readonly image: string;
  readonly claim: Input<string>;
  readonly envSecret: Input<string>;
  readonly pullSecret: Input<string>;
}

export function buildATCGatewayBackupPodSpec(inputs: BackupPodInputs) {
  return {
    restartPolicy: 'OnFailure',
    securityContext: buildATCPodSecurity(),
    automountServiceAccountToken: false,
    imagePullSecrets: [{ name: inputs.pullSecret }],
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
  } satisfies input.core.v1.PodSpec;
}

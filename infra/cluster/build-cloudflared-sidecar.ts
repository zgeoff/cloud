import type { input } from '@pulumi/kubernetes/types';
import { cloudflaredImage } from '../shared/cloudflared-image.ts';

// the pod's volume of the tunnel's token Secret, which only this container mounts
export const tunnelTokenVolume = 'tunnel-token';
const tunnelTokenDir = '/etc/cloudflared';

// The connector of a tunnel of the workload's own, which reaches the workload on the pod's
// loopback address.
export function buildCloudflaredSidecar() {
  return {
    name: 'cloudflared',
    image: cloudflaredImage,
    args: [
      'tunnel',
      '--no-autoupdate',
      '--metrics',

      // loopback, so nothing outside the pod reaches the metrics, which leaves kubelet no port to
      // probe
      '127.0.0.1:2000',
      'run',
      '--token-file',
      `${tunnelTokenDir}/token`,
    ],
    volumeMounts: [{ name: tunnelTokenVolume, mountPath: tunnelTokenDir, readOnly: true }],
    resources: {
      requests: { cpu: '10m', memory: '32Mi' },
      limits: { cpu: '200m', memory: '128Mi' },
    },
    securityContext: {
      runAsNonRoot: true,
      readOnlyRootFilesystem: true,
      allowPrivilegeEscalation: false,
      capabilities: { drop: ['ALL'] },
    },
  } satisfies input.core.v1.Container;
}

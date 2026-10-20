import { podLabels } from '../shared/pod-labels.ts';

export const cloudflaredNames = {
  namespace: 'ingress' as const,
  name: 'cloudflared',
  labels: podLabels.cloudflared,
  metricsPort: 'metrics',
};

export const cloudflaredNames = {
  namespace: 'ingress' as const,
  name: 'cloudflared',
  labels: { app: 'cloudflared' },
  metricsPort: 'metrics',
};

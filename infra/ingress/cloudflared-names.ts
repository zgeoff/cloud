// cloudflared's names in the cluster: its namespace, its Deployment and pod label, and the port
// that serves its Prometheus metrics. observability's PodMonitor and alert rule select on them.
export const cloudflaredNames = {
  namespace: 'ingress',
  name: 'cloudflared',
  labels: { app: 'cloudflared' },
  metricsPort: 'metrics',
};

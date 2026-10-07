import type { input } from '@pulumi/kubernetes/types';
import type { Output } from '@pulumi/pulumi';

// cloudflared's release; bump deliberately
const cloudflaredImage = 'cloudflare/cloudflared:2026.9.3';

// cloudflared's Deployment spec: two replicas, the tunnel token from tokenSecret, and
// Prometheus metrics on the `metrics` port, which the cloudflared PodMonitor
// (create-monitors.ts) scrapes
export function buildCloudflaredSpec(tokenSecret: Output<string>): input.apps.v1.DeploymentSpec {
  return {
    replicas: 2,
    selector: { matchLabels: { app: 'cloudflared' } },
    template: {
      metadata: { labels: { app: 'cloudflared' } },
      spec: {
        containers: [
          {
            name: 'cloudflared',
            image: cloudflaredImage,
            args: ['tunnel', '--no-autoupdate', '--metrics', '0.0.0.0:2000', 'run'],
            env: [
              {
                name: 'TUNNEL_TOKEN',
                valueFrom: { secretKeyRef: { name: tokenSecret, key: 'token' } },
              },
            ],
            ports: [{ name: 'metrics', containerPort: 2000 }],
            livenessProbe: { httpGet: { path: '/ready', port: 2000 }, periodSeconds: 10 },
            resources: { requests: { cpu: '10m', memory: '32Mi' }, limits: { memory: '128Mi' } },
          },
        ],
      },
    },
  };
}

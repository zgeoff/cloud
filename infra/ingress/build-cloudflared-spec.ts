import type { input } from '@pulumi/kubernetes/types';
import type { Output } from '@pulumi/pulumi';
import { cloudflaredImage } from '../shared/cloudflared-image.ts';
import { cloudflaredNames } from './cloudflared-names.ts';

// cloudflared's Deployment spec: two replicas, the tunnel token from tokenSecret, and
// Prometheus metrics on its metrics port, which the cloudflared PodMonitor
// (observability/create-monitors.ts) scrapes
export function buildCloudflaredSpec(tokenSecret: Output<string>): input.apps.v1.DeploymentSpec {
  return {
    replicas: 2,
    selector: { matchLabels: cloudflaredNames.labels },
    template: {
      metadata: { labels: cloudflaredNames.labels },
      spec: {
        containers: [
          {
            name: cloudflaredNames.name,
            image: cloudflaredImage,
            args: ['tunnel', '--no-autoupdate', '--metrics', '0.0.0.0:2000', 'run'],
            env: [
              {
                name: 'TUNNEL_TOKEN',
                valueFrom: { secretKeyRef: { name: tokenSecret, key: 'token' } },
              },
            ],
            ports: [{ name: cloudflaredNames.metricsPort, containerPort: 2000 }],
            livenessProbe: { httpGet: { path: '/ready', port: 2000 }, periodSeconds: 10 },
            resources: { requests: { cpu: '10m', memory: '32Mi' }, limits: { memory: '128Mi' } },
          },
        ],
      },
    },
  };
}

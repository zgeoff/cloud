import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildCloudflaredSpec } from './build-cloudflared-spec.ts';

test("it runs two tunnel replicas on the token Secret, serving metrics on a port named 'metrics'", () => {
  const tokenSecret = output('cloudflared-token');

  expect(buildCloudflaredSpec(tokenSecret)).toStrictEqual({
    replicas: 2,
    selector: { matchLabels: { app: 'cloudflared' } },
    template: {
      metadata: { labels: { app: 'cloudflared' } },
      spec: {
        containers: [
          {
            name: 'cloudflared',
            image: 'cloudflare/cloudflared:2026.9.3',
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
  });
});

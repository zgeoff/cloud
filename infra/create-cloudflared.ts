import type { Provider } from '@pulumi/kubernetes';
import { Deployment } from '@pulumi/kubernetes/apps/v1';
import { Namespace, Secret } from '@pulumi/kubernetes/core/v1';
import type { input } from '@pulumi/kubernetes/types';
import type { Output } from '@pulumi/pulumi';

// cloudflared's release; bump deliberately
const cloudflaredImage = 'cloudflare/cloudflared:2026.9.3';

interface CloudflaredOutputs {
  readonly ingressNamespace: Output<string>;
  readonly cloudflared: Deployment;
}

// The tunnel for every public hostname under geoff.cloud. The routes live in Cloudflare
// (ZeroTrustTunnelCloudflaredConfig), so this needs only the token.
export function createCloudflared(
  cluster: Provider,
  tunnelToken: Output<string>,
): CloudflaredOutputs {
  const ingress = new Namespace(
    'ingress',
    { metadata: { name: 'ingress' } },
    { provider: cluster },
  );

  const token = new Secret(
    'cloudflared-token',
    {
      metadata: { name: 'cloudflared-token', namespace: ingress.metadata.name },
      stringData: { token: tunnelToken },
    },
    { provider: cluster },
  );

  const cloudflared = new Deployment(
    'cloudflared',
    {
      metadata: { name: 'cloudflared', namespace: ingress.metadata.name },
      spec: buildCloudflaredSpec(token.metadata.name),
    },
    { provider: cluster },
  );

  return { ingressNamespace: ingress.metadata.name, cloudflared };
}

function buildCloudflaredSpec(tokenSecret: Output<string>): input.apps.v1.DeploymentSpec {
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

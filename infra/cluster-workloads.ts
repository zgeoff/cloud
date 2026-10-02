import { Provider } from '@pulumi/kubernetes';
import { Deployment } from '@pulumi/kubernetes/apps/v1';
import { Namespace, Secret } from '@pulumi/kubernetes/core/v1';
import type { input } from '@pulumi/kubernetes/types';
import type { Output } from '@pulumi/pulumi';

// cloudflared's release; bump deliberately
const cloudflaredImage = 'cloudflare/cloudflared:2026.9.3';

interface ClusterInputs {
  readonly kubeconfig: string;
  readonly tunnelToken: Output<string>;
}

interface ClusterOutputs {
  readonly ingressNamespace: Output<string>;
  readonly cloudflared: Deployment;
}

// Workloads on the geoffcloud k3s cluster (#6, #7, #8). Pulumi reaches the k3s API
// over the tailnet with the kubeconfig from op://cloud/k3s-kubeconfig.
export function createClusterWorkloads(inputs: ClusterInputs): ClusterOutputs {
  const cluster = new Provider('geoffcloud', { kubeconfig: inputs.kubeconfig });

  const ingress = new Namespace(
    'ingress',
    { metadata: { name: 'ingress' } },
    { provider: cluster },
  );

  const token = new Secret(
    'cloudflared-token',
    {
      metadata: { name: 'cloudflared-token', namespace: ingress.metadata.name },
      stringData: { token: inputs.tunnelToken },
    },
    { provider: cluster },
  );

  // The tunnel for every public hostname under geoff.cloud. The routes live in
  // Cloudflare (ZeroTrustTunnelCloudflaredConfig), so this needs only the token.
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

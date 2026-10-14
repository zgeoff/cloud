import type { Provider } from '@pulumi/kubernetes';
import { Deployment } from '@pulumi/kubernetes/apps/v1';
import { Namespace, Secret } from '@pulumi/kubernetes/core/v1';
import type { Output } from '@pulumi/pulumi';
import { buildCloudflaredSpec } from './build-cloudflared-spec.ts';

export interface CloudflaredOutputs {
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

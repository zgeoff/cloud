import type { Provider } from '@pulumi/kubernetes';
import { Deployment } from '@pulumi/kubernetes/apps/v1';
import { Secret } from '@pulumi/kubernetes/core/v1';
import type { Output } from '@pulumi/pulumi';
import { createEgressAllow } from '../shared/create-egress-allow.ts';
import { createNamespace } from '../shared/create-namespace.ts';
import { egressAllows } from '../shared/egress-allows.ts';
import { buildCloudflaredSpec } from './build-cloudflared-spec.ts';
import { cloudflaredNames } from './cloudflared-names.ts';

export function createCloudflared(cluster: Provider, tunnelToken: Output<string>): Deployment {
  const ingress = createNamespace(cloudflaredNames.namespace, cluster);

  // the routes live in Cloudflare, so the connector needs only the token
  const token = new Secret(
    'cloudflared-token',
    {
      metadata: { name: 'cloudflared-token', namespace: ingress.metadata.name },
      stringData: { token: tunnelToken },
    },
    { provider: cluster },
  );

  createEgressAllow(egressAllows.cloudflared, ingress.metadata.name, { provider: cluster });

  return new Deployment(
    'cloudflared',
    {
      metadata: { name: cloudflaredNames.name, namespace: ingress.metadata.name },
      spec: buildCloudflaredSpec(token.metadata.name),
    },
    { provider: cluster },
  );
}

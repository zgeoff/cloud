import { DnsRecord } from '@pulumi/cloudflare';
import type { Provider } from '@pulumi/kubernetes';
import { Ingress } from '@pulumi/kubernetes/networking/v1';
import type { input } from '@pulumi/kubernetes/types';
import type { Output } from '@pulumi/pulumi';
import { interpolate } from '@pulumi/pulumi';
import { geoffcloudNode } from '../shared/geoffcloud-node.ts';
import { createNixieCertificate } from './create-nixie-certificate.ts';
import type { NixieTailnetRoutes } from './create-nixie-ingress.ts';

interface PepysTailnetIngress {
  readonly annotations?: Readonly<Record<string, string>>;
  readonly spec: input.networking.v1.IngressSpec;
}

export interface PepysTailnetRouteInputs {
  // the resource name of the certificate, the Ingress and the DNS record
  readonly name: string;
  readonly hostname: string;
  readonly namespace: Output<string>;
  readonly routes: NixieTailnetRoutes;

  // the Ingress, given the Secret of the name's certificate
  readonly buildIngress: (tlsSecret: Output<string>) => PepysTailnetIngress;
}

export function createPepysTailnetRoute(
  cluster: Provider,
  inputs: PepysTailnetRouteInputs,
): Output<string> {
  const tlsSecret = createNixieCertificate(cluster, {
    name: inputs.name,
    account: inputs.routes.account,
    namespace: inputs.namespace,
    hostname: inputs.hostname,
    dnsToken: inputs.routes.dnsToken,
  });

  const ingress = inputs.buildIngress(tlsSecret);

  const resource = new Ingress(
    inputs.name,
    {
      metadata: {
        name: inputs.name,
        namespace: inputs.namespace,
        ...(ingress.annotations === undefined ? {} : { annotations: ingress.annotations }),
      },
      spec: ingress.spec,
    },

    // served by nixie's Traefik release once it runs
    { provider: cluster, dependsOn: [inputs.routes.controller] },
  );

  // created after the Ingress, so the name resolves once Traefik serves it
  const record = new DnsRecord(
    inputs.name,
    {
      zoneId: inputs.routes.zoneID,
      name: inputs.hostname,
      type: 'A',

      // the host's tailnet address, so the name answers on the tailnet only
      content: geoffcloudNode.ip,
      proxied: false,
      ttl: 1,
    },
    { dependsOn: [resource] },
  );

  return interpolate`https://${record.name}`;
}

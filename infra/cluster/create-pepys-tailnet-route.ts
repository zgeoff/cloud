import { DnsRecord } from '@pulumi/cloudflare';
import type { Provider } from '@pulumi/kubernetes';
import { Ingress } from '@pulumi/kubernetes/networking/v1';
import type { Output } from '@pulumi/pulumi';
import { interpolate } from '@pulumi/pulumi';
import { geoffcloudNode } from '../shared/geoffcloud-node.ts';
import { pepysWorkloads } from '../shared/pepys-workloads.ts';
import { buildPepysTailnetIngressSpec } from './build-pepys-tailnet-ingress-spec.ts';
import { createNixieCertificate } from './create-nixie-certificate.ts';
import type { NixieTailnetRoutes } from './create-nixie-ingress.ts';

export interface PepysTailnetRouteInputs {
  readonly hostname: string;
  readonly namespace: Output<string>;

  // resolves once the host's StatefulSet has rolled out, so the Ingress finds its endpoints
  readonly service: Output<string>;
  readonly routes: NixieTailnetRoutes;
}

const name = 'pepys-api-tailnet';

export function createPepysTailnetRoute(
  cluster: Provider,
  inputs: PepysTailnetRouteInputs,
): Output<string> {
  const tlsSecret = createNixieCertificate(cluster, {
    name,
    account: inputs.routes.account,
    namespace: inputs.namespace,
    hostname: inputs.hostname,
    dnsToken: inputs.routes.dnsToken,
  });

  const ingress = new Ingress(
    name,
    {
      metadata: { name, namespace: inputs.namespace },
      spec: buildPepysTailnetIngressSpec({
        hostname: inputs.hostname,
        ingressClass: inputs.routes.ingressClass,
        tlsSecret,
        service: inputs.service,
        port: pepysWorkloads.host.apiPort,
      }),
    },

    // served by nixie's Traefik release once it runs
    { provider: cluster, dependsOn: [inputs.routes.controller] },
  );

  // created after the Ingress, so the name resolves once Traefik serves it
  const record = new DnsRecord(
    name,
    {
      zoneId: inputs.routes.zoneID,
      name: inputs.hostname,
      type: 'A',

      // the host's tailnet address, so the API's every path answers on the tailnet only
      content: geoffcloudNode.ip,
      proxied: false,
      ttl: 1,
    },
    { dependsOn: [ingress] },
  );

  return interpolate`https://${record.name}`;
}

import { DnsRecord } from '@pulumi/cloudflare';
import type { Provider } from '@pulumi/kubernetes';
import { Chart } from '@pulumi/kubernetes/helm/v4';
import { Ingress } from '@pulumi/kubernetes/networking/v1';
import type { Output } from '@pulumi/pulumi';
import { interpolate } from '@pulumi/pulumi';
import { createNamespace } from '../shared/create-namespace.ts';
import { geoffcloudNode } from '../shared/geoffcloud-node.ts';
import { buildNixieIngressChartArgs } from './build-nixie-ingress-chart-args.ts';
import { buildNixieIngressSpec } from './build-nixie-ingress-spec.ts';
import { createNixieCertificate } from './create-nixie-certificate.ts';
import { makeHostIPTransform } from './make-host-ip-transform.ts';
import { makeMovedResourceTransform } from './make-moved-resource-transform.ts';

interface Backend {
  readonly service: Output<string>;
  readonly port: number;
}

export interface NixieIngressInputs {
  // nixie's namespace, which holds the Ingress and its certificate
  readonly namespace: Output<string>;
  readonly hostname: string;
  readonly dnsToken: Output<string>;
  readonly zoneID: Output<string>;
  readonly api: Backend;
  readonly web: Backend;
}

export interface NixieIngressOutputs {
  readonly url: Output<string>;
}

const ingressClass = 'nixie';

// Traefik, bound to the host's tailnet address, serves nixie's Ingress with the certificate the run
// issues; the public DNS name points at that tailnet address, so it answers on the tailnet only
export function createNixieIngress(
  cluster: Provider,
  inputs: NixieIngressInputs,
): NixieIngressOutputs {
  const controllerNamespace = createNamespace('nixie-ingress', cluster);

  const controller = new Chart(
    'nixie-ingress',
    buildNixieIngressChartArgs({
      controllerNamespace: 'nixie-ingress',
      routesNamespace: 'nixie',
      ingressClass,
    }),
    {
      provider: cluster,
      dependsOn: [controllerNamespace],
      transforms: [
        // 443 answers on the host's tailnet address and no other
        makeHostIPTransform(geoffcloudNode.ip, 'websecure', cluster),

        // the controller moved out of nixie's namespace, which Pod Security's baseline covers
        makeMovedResourceTransform(
          'kubernetes:apps/v1:Deployment',
          'nixie-ingress:nixie-ingress/nixie-ingress-traefik',
          'nixie-ingress:nixie/nixie-ingress-traefik',
        ),
      ],
    },
  );

  createIngress(cluster, inputs, controller);

  return { url: interpolate`https://${createRecord(inputs).name}` };
}

// nixie's Ingress, served by the Traefik release once it runs
function createIngress(cluster: Provider, inputs: NixieIngressInputs, controller: Chart): Ingress {
  return new Ingress(
    'nixie',
    {
      metadata: { name: 'nixie', namespace: inputs.namespace },
      spec: buildNixieIngressSpec({
        hostname: inputs.hostname,
        ingressClass,
        tlsSecret: createNixieCertificate(cluster, inputs),
        api: inputs.api,
        web: inputs.web,
      }),
    },
    { provider: cluster, dependsOn: [controller] },
  );
}

function createRecord(inputs: NixieIngressInputs): DnsRecord {
  return new DnsRecord('nixie', {
    zoneId: inputs.zoneID,
    name: inputs.hostname,
    type: 'A',
    content: geoffcloudNode.ip,
    proxied: false,
    ttl: 1,
  });
}

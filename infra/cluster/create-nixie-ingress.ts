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
import type { NixieACMEAccount } from './create-nixie-acme-account.ts';
import { createNixieACMEAccount } from './create-nixie-acme-account.ts';
import { createNixieCertificate } from './create-nixie-certificate.ts';
import { makeHostIPTransform } from './make-host-ip-transform.ts';

interface Backend {
  readonly service: Output<string>;
  readonly port: number;
}

export interface NixieIngressInputs {
  readonly namespace: Output<string>;
  readonly hostname: string;
  readonly dnsToken: Output<string>;
  readonly zoneID: Output<string>;
  readonly api: Backend;
  readonly web: Backend;

  // the namespaces whose Ingress objects the Traefik serves, nixie's among them
  readonly routesNamespaces: readonly string[];
}

// what another namespace's Ingress on the host's tailnet address needs from nixie's Traefik
export interface NixieTailnetRoutes {
  readonly controller: Chart;
  readonly ingressClass: string;
  readonly account: NixieACMEAccount;
  readonly dnsToken: Output<string>;
  readonly zoneID: Output<string>;
}

export interface NixieIngressOutputs {
  readonly url: Output<string>;
  readonly tailnetRoutes: NixieTailnetRoutes;
}

const ingressClass = 'nixie';

export function createNixieIngress(
  cluster: Provider,
  inputs: NixieIngressInputs,
): NixieIngressOutputs {
  const controllerNamespace = createNamespace('nixie-ingress', cluster);

  const controller = new Chart(
    'nixie-ingress',
    buildNixieIngressChartArgs({
      controllerNamespace: 'nixie-ingress',
      routesNamespaces: inputs.routesNamespaces,
      ingressClass,
    }),
    {
      provider: cluster,
      dependsOn: [controllerNamespace],
      transforms: [
        // 443 answers on the host's tailnet address and no other
        makeHostIPTransform(geoffcloudNode.ip, 'websecure', cluster),
      ],
    },
  );

  const account = createNixieACMEAccount();

  createIngress(cluster, inputs, controller, account);

  return {
    url: interpolate`https://${createRecord(inputs).name}`,
    tailnetRoutes: {
      controller,
      ingressClass,
      account,
      dnsToken: inputs.dnsToken,
      zoneID: inputs.zoneID,
    },
  };
}

function createIngress(
  cluster: Provider,
  inputs: NixieIngressInputs,
  controller: Chart,
  account: NixieACMEAccount,
): Ingress {
  return new Ingress(
    'nixie',
    {
      metadata: { name: 'nixie', namespace: inputs.namespace },
      spec: buildNixieIngressSpec({
        hostname: inputs.hostname,
        ingressClass,
        tlsSecret: createNixieCertificate(cluster, {
          name: 'nixie',
          account,
          namespace: inputs.namespace,
          hostname: inputs.hostname,
          dnsToken: inputs.dnsToken,
        }),
        api: inputs.api,
        web: inputs.web,
      }),
    },

    // served by the Traefik release once it runs
    { provider: cluster, dependsOn: [controller] },
  );
}

function createRecord(inputs: NixieIngressInputs): DnsRecord {
  return new DnsRecord('nixie', {
    zoneId: inputs.zoneID,
    name: inputs.hostname,
    type: 'A',

    // the host's tailnet address, so nixie answers on the tailnet only
    content: geoffcloudNode.ip,
    proxied: false,
    ttl: 1,
  });
}

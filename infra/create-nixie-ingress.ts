import { DnsRecord } from '@pulumi/cloudflare';
import type { Provider } from '@pulumi/kubernetes';
import { Chart } from '@pulumi/kubernetes/helm/v4';
import { Ingress } from '@pulumi/kubernetes/networking/v1';
import type { Output, Resource } from '@pulumi/pulumi';
import { interpolate } from '@pulumi/pulumi';
import { buildNixieIngressSpec } from './build-nixie-ingress-spec.ts';
import { buildNixieIngressValues } from './build-nixie-ingress-values.ts';
import { createNixieCertificate } from './create-nixie-certificate.ts';
import { geoffcloudNode } from './geoffcloud-node.ts';
import { makeHostIPTransform } from './make-host-ip-transform.ts';

interface Backend {
  readonly service: Output<string>;
  readonly port: number;
}

export interface NixieIngressInputs {
  readonly namespace: Output<string>;

  // the namespace resource, which the controller's chart waits on
  readonly namespaceResource: Resource;
  readonly hostname: string;
  readonly dnsToken: Output<string>;
  readonly zoneID: Output<string>;
  readonly api: Backend;
  readonly web: Backend;
}

export interface NixieIngressOutputs {
  readonly ingress: Ingress;
  readonly url: Output<string>;
}

const ingressClass = 'nixie';

// Traefik, bound to the host's tailnet address, serves nixie's Ingress with the certificate the run
// issues; the public DNS name points at that tailnet address, so it answers on the tailnet only
export function createNixieIngress(
  cluster: Provider,
  inputs: NixieIngressInputs,
): NixieIngressOutputs {
  const controller = new Chart(
    'nixie-ingress',
    {
      namespace: inputs.namespace,
      chart: 'traefik',
      version: '41.6.0',
      repositoryOpts: { repo: 'https://traefik.github.io/charts' },

      // Ingress objects only: no Traefik, Hub or Gateway CRDs in the cluster
      skipCrds: true,
      values: buildNixieIngressValues({
        httpsPort: geoffcloudNode.httpsPort,
        endpointIP: geoffcloudNode.ip,
        ingressClass,
        namespace: 'nixie',
      }),
    },
    {
      provider: cluster,
      dependsOn: [inputs.namespaceResource],

      // 443 answers on the host's tailnet address and no other
      transforms: [makeHostIPTransform(geoffcloudNode.ip, 'websecure')],
    },
  );

  const ingress = new Ingress(
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

  return { ingress, url: interpolate`https://${createRecord(inputs).name}` };
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

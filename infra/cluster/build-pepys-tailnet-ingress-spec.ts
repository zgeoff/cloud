import type { input } from '@pulumi/kubernetes/types';
import type { Output } from '@pulumi/pulumi';

export interface PepysTailnetIngressSpecInputs {
  readonly hostname: string;
  readonly ingressClass: string;
  readonly tlsSecret: Output<string>;
  readonly service: Output<string>;
  readonly port: number;
}

// every path, /rpc included: the name answers on the host's tailnet address alone
export function buildPepysTailnetIngressSpec(
  inputs: PepysTailnetIngressSpecInputs,
): input.networking.v1.IngressSpec {
  return {
    ingressClassName: inputs.ingressClass,
    tls: [{ hosts: [inputs.hostname], secretName: inputs.tlsSecret }],
    rules: [
      {
        host: inputs.hostname,
        http: {
          paths: [
            {
              path: '/',
              pathType: 'Prefix',
              backend: { service: { name: inputs.service, port: { number: inputs.port } } },
            },
          ],
        },
      },
    ],
  };
}

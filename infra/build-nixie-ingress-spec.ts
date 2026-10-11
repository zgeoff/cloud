import type { input } from '@pulumi/kubernetes/types';
import type { Output } from '@pulumi/pulumi';

export interface NixieIngressSpecInputs {
  // the one host name for the web client and the API
  readonly hostname: string;
  readonly ingressClass: string;
  readonly tlsSecret: Output<string>;
  readonly api: { readonly service: Output<string>; readonly port: number };
  readonly web: { readonly service: Output<string>; readonly port: number };
}

// nixie's Ingress: one host name, /rpc to nixie and every other path to the web client, with TLS
// from the certificate the Pulumi run issues
export function buildNixieIngressSpec(
  inputs: NixieIngressSpecInputs,
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
              path: '/rpc',
              pathType: 'Prefix',
              backend: { service: { name: inputs.api.service, port: { number: inputs.api.port } } },
            },
            {
              path: '/',
              pathType: 'Prefix',
              backend: { service: { name: inputs.web.service, port: { number: inputs.web.port } } },
            },
          ],
        },
      },
    ],
  };
}

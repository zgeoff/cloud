import type { input } from '@pulumi/kubernetes/types';
import type { Output } from '@pulumi/pulumi';
import { pepysForwarderMiddlewares } from './pepys-forwarder-middlewares.ts';

export interface PepysForwarderIngressInputs {
  readonly hostname: string;
  readonly ingressClass: string;
  readonly tlsSecret: Output<string>;
  readonly service: Output<string>;
  readonly port: number;
}

export interface PepysForwarderIngress {
  readonly annotations: Readonly<Record<string, string>>;
  readonly spec: input.networking.v1.IngressSpec;
}

// The forwarders' sender route alone: Traefik answers 404 itself on every other path of the name,
// so none of ingest's other routes, whose checks differ, answers on the tailnet. Without the
// annotation Traefik would pass a body of any size.
export function buildPepysForwarderIngress(
  inputs: PepysForwarderIngressInputs,
): PepysForwarderIngress {
  return {
    annotations: {
      'traefik.ingress.kubernetes.io/router.middlewares': pepysForwarderMiddlewares.annotation,
    },
    spec: {
      ingressClassName: inputs.ingressClass,
      tls: [{ hosts: [inputs.hostname], secretName: inputs.tlsSecret }],
      rules: [
        {
          host: inputs.hostname,
          http: {
            paths: [
              {
                path: '/forwarded/v1/logs',
                pathType: 'Exact',
                backend: { service: { name: inputs.service, port: { number: inputs.port } } },
              },
            ],
          },
        },
      ],
    },
  };
}

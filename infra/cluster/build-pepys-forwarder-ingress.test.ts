import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildPepysForwarderIngress } from './build-pepys-forwarder-ingress.ts';

test("it sends only the exact path /forwarded/v1/logs of the name to ingest's port, through the slot, in-flight and body limits", () => {
  const tlsSecret = output('pepys-forwarder-tailnet-tls-0a1b2c3d');
  const service = output('pepys-ingest');

  expect(
    buildPepysForwarderIngress({
      hostname: 'pepys-forwarder.geoff.cloud',
      ingressClass: 'nixie',
      tlsSecret,
      service,
      port: 8080,
    }),
  ).toStrictEqual({
    annotations: {
      'traefik.ingress.kubernetes.io/router.middlewares':
        'pepys-forwarder-slot@file,pepys-forwarder-in-flight@file,pepys-forwarder-body-limit@file',
    },
    spec: {
      ingressClassName: 'nixie',
      tls: [{ hosts: ['pepys-forwarder.geoff.cloud'], secretName: tlsSecret }],
      rules: [
        {
          host: 'pepys-forwarder.geoff.cloud',
          http: {
            paths: [
              {
                path: '/forwarded/v1/logs',
                pathType: 'Exact',
                backend: { service: { name: service, port: { number: 8080 } } },
              },
            ],
          },
        },
      ],
    },
  });
});

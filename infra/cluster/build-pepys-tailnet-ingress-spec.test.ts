import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildPepysTailnetIngressSpec } from './build-pepys-tailnet-ingress-spec.ts';

test("it sends every path of the tailnet host, /rpc among them, to the API's port", () => {
  const tlsSecret = output('pepys-api-tailnet-tls-0a1b2c3d');
  const service = output('pepys-host');

  expect(
    buildPepysTailnetIngressSpec({
      hostname: 'pepys-api.geoff.cloud',
      ingressClass: 'nixie',
      tlsSecret,
      service,
      port: 8081,
    }),
  ).toStrictEqual({
    ingressClassName: 'nixie',
    tls: [{ hosts: ['pepys-api.geoff.cloud'], secretName: tlsSecret }],
    rules: [
      {
        host: 'pepys-api.geoff.cloud',
        http: {
          paths: [
            {
              path: '/',
              pathType: 'Prefix',
              backend: { service: { name: service, port: { number: 8081 } } },
            },
          ],
        },
      },
    ],
  });
});

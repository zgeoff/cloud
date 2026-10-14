import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildNixieIngressSpec } from './build-nixie-ingress-spec.ts';

test('it sends /rpc to nixie and every other path to the web client on one TLS host name', () => {
  const tlsSecret = output('nixie-tls-0a1b2c3d');
  const apiService = output('nixie');
  const webService = output('nixie-web');

  expect(
    buildNixieIngressSpec({
      hostname: 'nixie.geoff.cloud',
      ingressClass: 'nixie',
      tlsSecret,
      api: { service: apiService, port: 8080 },
      web: { service: webService, port: 3000 },
    }),
  ).toStrictEqual({
    ingressClassName: 'nixie',
    tls: [{ hosts: ['nixie.geoff.cloud'], secretName: tlsSecret }],
    rules: [
      {
        host: 'nixie.geoff.cloud',
        http: {
          paths: [
            {
              path: '/rpc',
              pathType: 'Prefix',
              backend: { service: { name: apiService, port: { number: 8080 } } },
            },
            {
              path: '/',
              pathType: 'Prefix',
              backend: { service: { name: webService, port: { number: 3000 } } },
            },
          ],
        },
      },
    ],
  });
});

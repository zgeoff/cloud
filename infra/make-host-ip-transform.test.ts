// the test asserts whole resource props as literals, so its bodies are long
/* oxlint-disable max-lines-per-function */
import { expect, test } from 'bun:test';
import { makeHostIPTransform } from './make-host-ip-transform.ts';

test("it binds the named port of a Deployment's containers to the host address and leaves every other port alone", async () => {
  const transform = makeHostIPTransform('100.69.47.33', 'websecure');

  const result = await transform({
    custom: true,
    type: 'kubernetes:apps/v1:Deployment',
    name: 'nixie-ingress:nixie/nixie-ingress-traefik',
    props: {
      metadata: { name: 'nixie-ingress-traefik' },
      spec: {
        replicas: 1,
        template: {
          metadata: { labels: { app: 'traefik' } },
          spec: {
            serviceAccountName: 'nixie-ingress-traefik',
            containers: [
              {
                name: 'traefik',
                ports: [
                  { name: 'web', containerPort: 8000, protocol: 'TCP' },
                  { name: 'websecure', containerPort: 8443, hostPort: 443, protocol: 'TCP' },
                ],
              },
              { name: 'sidecar' },
            ],
          },
        },
      },
    },
    opts: { protect: false },
  });

  expect(result).toStrictEqual({
    props: {
      metadata: { name: 'nixie-ingress-traefik' },
      spec: {
        replicas: 1,
        template: {
          metadata: { labels: { app: 'traefik' } },
          spec: {
            serviceAccountName: 'nixie-ingress-traefik',
            containers: [
              {
                name: 'traefik',
                ports: [
                  { name: 'web', containerPort: 8000, protocol: 'TCP' },
                  {
                    name: 'websecure',
                    containerPort: 8443,
                    hostPort: 443,
                    protocol: 'TCP',
                    hostIP: '100.69.47.33',
                  },
                ],
              },
              { name: 'sidecar' },
            ],
          },
        },
      },
    },
    opts: { protect: false },
  });
});

test('it passes a resource that is not a Deployment through unchanged', async () => {
  const transform = makeHostIPTransform('100.69.47.33', 'websecure');

  const result = await transform({
    custom: true,
    type: 'kubernetes:core/v1:Service',
    name: 'nixie-ingress:nixie/nixie-ingress-traefik',
    props: { spec: { type: 'ClusterIP' } },
    opts: {},
  });

  expect(result).toStrictEqual({ props: { spec: { type: 'ClusterIP' } }, opts: {} });
});

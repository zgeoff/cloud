import { expect, test } from 'bun:test';
import { DependencyProviderResource, output } from '@pulumi/pulumi';
import { makeHostIPTransform } from './make-host-ip-transform.ts';

test("it binds the named port of a Deployment's containers to the host address and leaves every other port alone", async () => {
  const provider = new DependencyProviderResource(
    'urn:pulumi:prod::geoff-cloud::pulumi:providers:kubernetes::geoffcloud::0b8c8d3e',
  );

  const transform = makeHostIPTransform('100.69.47.33', 'websecure', provider);

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
    opts: { protect: false, provider },
  });
});

test("it keeps the Outputs in a Deployment's props by reference when it binds the port", async () => {
  const provider = new DependencyProviderResource(
    'urn:pulumi:prod::geoff-cloud::pulumi:providers:kubernetes::geoffcloud::0b8c8d3e',
  );

  const transform = makeHostIPTransform('100.69.47.33', 'websecure', provider);
  const namespace = output('nixie');
  const image = output('traefik:v3');

  const result = await transform({
    custom: true,
    type: 'kubernetes:apps/v1:Deployment',
    name: 'nixie-ingress:nixie/nixie-ingress-traefik',
    props: {
      metadata: { name: 'nixie-ingress-traefik', namespace },
      spec: {
        template: {
          spec: {
            containers: [
              {
                name: 'traefik',
                image,
                ports: [{ name: 'websecure', containerPort: 8443, hostPort: 443 }],
              },
            ],
          },
        },
      },
    },
    opts: {},
  });

  expect(result).toStrictEqual({
    props: {
      metadata: { name: 'nixie-ingress-traefik', namespace },
      spec: {
        template: {
          spec: {
            containers: [
              {
                name: 'traefik',
                image,
                ports: [
                  { name: 'websecure', containerPort: 8443, hostPort: 443, hostIP: '100.69.47.33' },
                ],
              },
            ],
          },
        },
      },
    },
    opts: { provider },
  });
});

test('it passes a pod template that is an Output through unchanged', async () => {
  const provider = new DependencyProviderResource(
    'urn:pulumi:prod::geoff-cloud::pulumi:providers:kubernetes::geoffcloud::0b8c8d3e',
  );

  const transform = makeHostIPTransform('100.69.47.33', 'websecure', provider);
  const template = output({ spec: { containers: [] } });

  const result = await transform({
    custom: true,
    type: 'kubernetes:apps/v1:Deployment',
    name: 'nixie-ingress:nixie/nixie-ingress-traefik',
    props: { spec: { replicas: 1, template } },
    opts: {},
  });

  expect(result).toStrictEqual({
    props: { spec: { replicas: 1, template } },
    opts: { provider },
  });
});

test('it leaves a resource that is not a Deployment to keep its own options', async () => {
  const provider = new DependencyProviderResource(
    'urn:pulumi:prod::geoff-cloud::pulumi:providers:kubernetes::geoffcloud::0b8c8d3e',
  );

  const transform = makeHostIPTransform('100.69.47.33', 'websecure', provider);

  const result = await transform({
    custom: true,
    type: 'kubernetes:core/v1:Service',
    name: 'nixie-ingress:nixie/nixie-ingress-traefik',
    props: { spec: { type: 'ClusterIP' } },
    opts: {},
  });

  expect(result).toBeUndefined();
});

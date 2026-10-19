import { expect, test } from 'bun:test';
import type { CustomResourceOptions } from '@pulumi/pulumi';
import { DependencyProviderResource } from '@pulumi/pulumi';
import { makeMovedResourceTransform } from './make-moved-resource-transform.ts';

test('it aliases the named resource to its previous name and deletes the old object before it creates the new one', async () => {
  const provider = new DependencyProviderResource(
    'urn:pulumi:prod::geoff-cloud::pulumi:providers:kubernetes::geoffcloud::0b8c8d3e',
  );

  const transform = makeMovedResourceTransform(
    'kubernetes:apps/v1:Deployment',
    'web-ingress:web-ingress/web-ingress-traefik',
    'web-ingress:web/web-ingress-traefik',
  );

  const props = { metadata: { name: 'web-ingress-traefik', namespace: 'web-ingress' } };

  const result = await transform({
    custom: true,
    type: 'kubernetes:apps/v1:Deployment',
    name: 'web-ingress:web-ingress/web-ingress-traefik',
    props,
    opts: { provider },
  });

  const opts: CustomResourceOptions = {
    provider,
    aliases: [{ name: 'web-ingress:web/web-ingress-traefik' }],
    deleteBeforeReplace: true,
  };

  expect(result).toStrictEqual({ props, opts });
});

test('it leaves a resource of the same type with another name alone', async () => {
  const transform = makeMovedResourceTransform(
    'kubernetes:apps/v1:Deployment',
    'web-ingress:web-ingress/web-ingress-traefik',
    'web-ingress:web/web-ingress-traefik',
  );

  const result = await transform({
    custom: true,
    type: 'kubernetes:apps/v1:Deployment',
    name: 'web-ingress:web-ingress/web-ingress-sidecar',
    props: { metadata: { name: 'web-ingress-sidecar' } },
    opts: {},
  });

  expect(result).toBeUndefined();
});

test('it leaves a resource of another type with the same name alone', async () => {
  const transform = makeMovedResourceTransform(
    'kubernetes:apps/v1:Deployment',
    'web-ingress:web-ingress/web-ingress-traefik',
    'web-ingress:web/web-ingress-traefik',
  );

  const result = await transform({
    custom: true,
    type: 'kubernetes:core/v1:Service',
    name: 'web-ingress:web-ingress/web-ingress-traefik',
    props: { metadata: { name: 'web-ingress-traefik' } },
    opts: {},
  });

  expect(result).toBeUndefined();
});

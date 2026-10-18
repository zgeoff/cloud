import { expect, test } from 'bun:test';
import { DependencyProviderResource, output } from '@pulumi/pulumi';
import { makeDeleteBeforeReplaceTransform } from './make-delete-before-replace-transform.ts';

test("it deletes a chart's fixed-name Secret before it creates the replacement, keeping its props and options", async () => {
  const provider = new DependencyProviderResource(
    'urn:pulumi:prod::geoff-cloud::pulumi:providers:kubernetes::geoffcloud::0b8c8d3e',
  );

  const transform = makeDeleteBeforeReplaceTransform(provider);
  const data = output({ 'alertmanager.yaml': 'cm91dGU6IHt9' });

  const result = await transform({
    custom: true,
    type: 'kubernetes:core/v1:Secret',
    name: 'kube-prometheus-stack:observability/alertmanager-kube-prometheus-stack-alertmanager',
    props: {
      metadata: { name: 'alertmanager-kube-prometheus-stack-alertmanager' },
      data,
    },
    opts: { protect: false },
  });

  // a transform's result is typed ResourceOptions, which has no deleteBeforeReplace
  expect<unknown>(result).toStrictEqual({
    props: {
      metadata: { name: 'alertmanager-kube-prometheus-stack-alertmanager' },
      data,
    },
    opts: { protect: false, deleteBeforeReplace: true, provider },
  });
});

test("it deletes a chart's fixed-name ConfigMap before it creates the replacement", async () => {
  const provider = new DependencyProviderResource(
    'urn:pulumi:prod::geoff-cloud::pulumi:providers:kubernetes::geoffcloud::0b8c8d3e',
  );

  const transform = makeDeleteBeforeReplaceTransform(provider);

  const result = await transform({
    custom: true,
    type: 'kubernetes:core/v1:ConfigMap',
    name: 'alloy:observability/alloy',
    props: { metadata: { name: 'alloy' }, data: { 'config.alloy': 'logging {}\n' } },
    opts: {},
  });

  // a transform's result is typed ResourceOptions, which has no deleteBeforeReplace
  expect<unknown>(result).toStrictEqual({
    props: { metadata: { name: 'alloy' }, data: { 'config.alloy': 'logging {}\n' } },
    opts: { deleteBeforeReplace: true, provider },
  });
});

test('it leaves a resource that is neither a ConfigMap nor a Secret to keep its own options', async () => {
  const provider = new DependencyProviderResource(
    'urn:pulumi:prod::geoff-cloud::pulumi:providers:kubernetes::geoffcloud::0b8c8d3e',
  );

  const transform = makeDeleteBeforeReplaceTransform(provider);

  const result = await transform({
    custom: true,
    type: 'kubernetes:apps/v1:DaemonSet',
    name: 'alloy:observability/alloy',
    props: { spec: { selector: { matchLabels: { app: 'alloy' } } } },
    opts: {},
  });

  expect(result).toBeUndefined();
});

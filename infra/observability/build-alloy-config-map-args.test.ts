import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { alloyConfig } from './alloy-config.ts';
import { buildAlloyConfigMapArgs } from './build-alloy-config-map-args.ts';

test('it holds the Alloy config under no name of its own, so Pulumi gives each replacement a new name and no create meets a ConfigMap that exists', () => {
  const namespace = output('observability');

  expect(buildAlloyConfigMapArgs(namespace)).toStrictEqual({
    metadata: { namespace },
    data: { 'config.alloy': alloyConfig },
  });
});

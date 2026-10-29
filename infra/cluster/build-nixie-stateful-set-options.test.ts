import { expect, onTestFinished, test } from 'bun:test';
import { Command } from '@pulumi/command/local';
import { output, runtime } from '@pulumi/pulumi';
import { buildStubResourceMocks } from '../test-utils/build-stub-resource-mocks.ts';
import { buildNixieStatefulSetOptions } from './build-nixie-stateful-set-options.ts';
import { createClusterProvider } from './create-cluster-provider.ts';

async function setupTest() {
  const stub = buildStubResourceMocks();

  await runtime.setMocks(stub.mocks, 'geoff-cloud', 'test');

  onTestFinished(() => {
    stub.release();
    runtime.resetOptions('', '', -1, '', '', false, '');
  });

  return { stub };
}

test('it makes the StatefulSet wait on the sandbox image Command, with 30 minutes for each rollout', async () => {
  await setupTest();

  const cluster = createClusterProvider('k3s', { kubeconfig: output('kubeconfig-for-tests') });

  const sandboxImages = new Command('nixie-sandbox-images', { create: 'true' });

  expect(buildNixieStatefulSetOptions({ cluster, sandboxImages })).toStrictEqual({
    provider: cluster,
    customTimeouts: { create: '30m', update: '30m' },
    dependsOn: [sandboxImages],
  });
});

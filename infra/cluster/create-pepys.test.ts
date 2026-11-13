import { expect, onTestFinished, test } from 'bun:test';
import { output, runtime } from '@pulumi/pulumi';
import type { PepysInputs } from '../inputs/index.ts';
import { buildStubResourceMocks } from '../test-utils/build-stub-resource-mocks.ts';
import { resolveOutput } from '../test-utils/resolve-output.ts';
import { createClusterProvider } from './create-cluster-provider.ts';
import { createPepys } from './create-pepys.ts';

async function setupTest() {
  // a held registration stands in for a host roll that has not finished
  const hostKey = 'kubernetes:apps/v1:StatefulSet::pepys-host';
  const stub = buildStubResourceMocks([hostKey]);

  await runtime.setMocks(stub.mocks, 'geoff-cloud', 'test');

  onTestFinished(() => {
    stub.release();
    runtime.resetOptions('', '', -1, '', '', false, '');
  });

  const inputs: PepysInputs = {
    config: {
      image:
        'ghcr.io/zgeoff/cloud-pepys:0.3.1-3f9c1d2a7b10@sha256:4444444444444444444444444444444444444444444444444444444444444444',
      webhookHostname: 'pepys-webhook.geoff.cloud',
      apiHostname: 'pepys.geoff.cloud',
    },
    pullCredential: {
      username: 'octo-puller',
      token: output('ghp_fake0token0for0tests0only0000000000'),
    },
    secrets: {
      garageRPCSecret: output('garage-rpc-secret-for-tests'),
      garageAdminToken: output('garage-admin-token-for-tests'),
      s2GarageAccessKeyID: output('GK0123456789abcdef01234567'),
      s2GarageSecretAccessKey: output('s2-garage-secret-for-tests'),
      s2AccessToken: output('s2-access-token-for-tests'),
      ingest: {},
    },
  };

  return {
    stub,
    hostKey,
    outputs: createPepys(
      createClusterProvider('k3s', { kubeconfig: output('kubeconfig-for-tests') }),
      inputs,
    ),
  };
}

// The tunnel config takes the route's service as an input, so it can't register the route before
// that Output resolves. An older API serves /mcp to any caller, so the route waits for the host.
test("it holds the API route's service until the host's StatefulSet is ready", async () => {
  const ctx = await setupTest();

  const service = ctx.outputs.apiRoute?.service;
  const order: string[] = [];

  const resolving = (async () => {
    order.push(`route ${await resolveOutput(output(service))}`);
  })();

  await ctx.stub.whenRegistered(ctx.hostKey);

  order.push('host ready');
  ctx.stub.releaseKey(ctx.hostKey);

  await resolving;

  expect(order).toStrictEqual([
    'host ready',
    'route http://pepys-host.pepys.svc.cluster.local:8081',
  ]);
});

import { expect, test } from 'bun:test';
import { checkGatewayObjects } from './check-gateway-objects.ts';
import { buildStubReadinessHost } from './test-utils/build-stub-readiness-host.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';

test('it reports each object the deploy creates as present or missing, in order', async () => {
  const stub = buildStubRunner(
    buildStubReadinessHost({
      destination: 'root@geoffcloud',
      nodeLine: '',
      availableMiB: 0,
      namespaces: ['atc'],
      storageClasses: [],
      deployments: { 'atc/atc-gateway': 0 },
      isDaemonActive: false,
      impdHealth: '',
      probeCode: '',
    }),
  );

  const lines = await checkGatewayObjects({ run: stub.run, host: 'geoffcloud' });

  expect(lines).toStrictEqual([
    { status: 'ok', text: 'exists: namespace atc' },
    { status: 'missing', text: 'storageclass local-path-retain' },
    { status: 'ok', text: 'exists: -n atc deploy atc-gateway' },
  ]);
});

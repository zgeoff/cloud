import { expect, test } from 'bun:test';
import { checkGatewayInCluster } from './check-gateway-in-cluster.ts';
import { buildStubReadinessHost } from './test-utils/build-stub-readiness-host.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';

test('it probes the gateway in the cluster with its public Host, with a long timeout', async () => {
  const stub = buildStubRunner(
    buildStubReadinessHost({
      destination: 'root@geoffcloud',
      nodeLine: '',
      availableMiB: 0,
      namespaces: [],
      storageClasses: [],
      deployments: { 'atc/atc-gateway': 1 },
      isDaemonActive: false,
      impdHealth: '',
      probeCode: '200',
    }),
  );

  const lines = await checkGatewayInCluster({ run: stub.run, host: 'geoffcloud' });

  expect(lines).toStrictEqual([{ status: 'ok', text: 'gateway in-cluster metadata: 200' }]);
  expect(stub.calls[1]?.options.timeoutMs).toBe(300_000);
});

test('it checks nothing before the deploy creates the gateway', async () => {
  const stub = buildStubRunner(
    buildStubReadinessHost({
      destination: 'root@geoffcloud',
      nodeLine: '',
      availableMiB: 0,
      namespaces: [],
      storageClasses: [],
      deployments: {},
      isDaemonActive: false,
      impdHealth: '',
      probeCode: '200',
    }),
  );

  const lines = await checkGatewayInCluster({ run: stub.run, host: 'geoffcloud' });

  expect(lines).toStrictEqual([]);
  expect(stub.calls).toHaveLength(1);
});

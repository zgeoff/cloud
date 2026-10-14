import { expect, test } from 'bun:test';
import { checkGatewayHost } from './check-gateway-host.ts';
import { buildStubReadinessHost } from './test-utils/build-stub-readiness-host.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';

test('it passes a Ready node with enough memory and a ready tunnel', async () => {
  const stub = buildStubRunner(
    buildStubReadinessHost({
      destination: 'root@geoffcloud',
      nodeLine: 'geoffcloud   Ready    control-plane,master   40d   v1.33.4+k3s1',
      availableMiB: 4096,
      namespaces: [],
      storageClasses: [],
      deployments: { 'ingress/cloudflared': 2 },
      isDaemonActive: false,
      impdHealth: '',
      probeCode: '',
    }),
  );

  const lines = await checkGatewayHost({ run: stub.run, host: 'geoffcloud' });

  expect(lines).toStrictEqual([
    { status: 'ok', text: 'k3s node on geoffcloud is Ready' },
    { status: 'ok', text: 'host has 4096 MiB available (gateway needs 256 MiB)' },
    { status: 'ok', text: 'cloudflared has ready replicas' },
  ]);
});

test('it fails a node list with more than one node, and a tunnel with no Deployment', async () => {
  const stub = buildStubRunner(
    buildStubReadinessHost({
      destination: 'root@geoffcloud',
      nodeLine:
        'geoffcloud   Ready    control-plane   40d   v1.33.4+k3s1\nother   Ready    <none>   1d   v1.33.4+k3s1',
      availableMiB: 4096,
      namespaces: [],
      storageClasses: [],
      deployments: {},
      isDaemonActive: false,
      impdHealth: '',
      probeCode: '',
    }),
  );

  const lines = await checkGatewayHost({ run: stub.run, host: 'geoffcloud' });

  expect(lines[0]?.status).toBe('FAIL');
  expect(lines[2]).toStrictEqual({ status: 'FAIL', text: 'cloudflared has no ready replica' });
});

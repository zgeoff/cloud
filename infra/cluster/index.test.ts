import { expect, onTestFinished, test } from 'bun:test';
import { output, runtime } from '@pulumi/pulumi';
import { buildStubResourceMocks } from '../test-utils/build-stub-resource-mocks.ts';
import { resolveOutput } from '../test-utils/resolve-output.ts';
import { createCluster, createClusterProvider } from './index.ts';

test("it returns the files service's route, from its configured host to its Service, when files is set", async () => {
  const stub = buildStubResourceMocks();

  await runtime.setMocks(stub.mocks, 'geoff-cloud', 'test');

  onTestFinished(() => {
    stub.release();
    runtime.resetOptions('', '', -1, '', '', false, '');
  });

  const workloads = createCluster(
    createClusterProvider('k3s', { kubeconfig: output('kubeconfig-for-tests') }),
    {
      onePasswordConnect: { credentials: output('{}') },
      files: {
        config: {
          image:
            'ghcr.io/zgeoff/cloud-files:0123456@sha256:3333333333333333333333333333333333333333333333333333333333333333',
          hostname: 'files.geoff.cloud',
        },
        pullCredential: {
          username: 'octo-puller',
          token: output('ghp_fake0token0for0tests0only0000000000'),
        },
        tokenHashes: { agent: output('a'.repeat(64)), owner: output('b'.repeat(64)) },
      },
      zoneID: output('zone'),
    },
  );

  if (workloads.filesRoute === undefined) {
    throw new Error('the cluster returned no files route');
  }

  const service = await resolveOutput(workloads.filesRoute.service);

  expect(workloads.filesRoute.hostname).toBe('files.geoff.cloud');
  expect(service).toBe('http://files.files.svc.cluster.local:8080');
});

test('it returns no files route while files is unset', async () => {
  const stub = buildStubResourceMocks();

  await runtime.setMocks(stub.mocks, 'geoff-cloud', 'test');

  onTestFinished(() => {
    stub.release();
    runtime.resetOptions('', '', -1, '', '', false, '');
  });

  const workloads = createCluster(
    createClusterProvider('k3s', { kubeconfig: output('kubeconfig-for-tests') }),
    {
      onePasswordConnect: { credentials: output('{}') },
      zoneID: output('zone'),
    },
  );

  expect(workloads.filesRoute).toBeUndefined();
});

test('it creates the egress deny in each namespace k3s creates, kube-system and default included', async () => {
  const stub = buildStubResourceMocks();

  await runtime.setMocks(stub.mocks, 'geoff-cloud', 'test');

  onTestFinished(() => {
    stub.release();
    runtime.resetOptions('', '', -1, '', '', false, '');
  });

  createCluster(createClusterProvider('k3s', { kubeconfig: output('kubeconfig-for-tests') }), {
    onePasswordConnect: { credentials: output('{}') },
    zoneID: output('zone'),
  });

  await Promise.all(
    ['default', 'kube-node-lease', 'kube-public', 'kube-system'].map((namespace) =>
      stub.whenRegistered(
        `kubernetes:networking.k8s.io/v1:NetworkPolicy::${namespace}-egress-deny`,
      ),
    ),
  );

  expect(
    stub.inputs.get('kubernetes:networking.k8s.io/v1:NetworkPolicy::kube-system-egress-deny'),
  ).toStrictEqual({
    apiVersion: 'networking.k8s.io/v1',
    kind: 'NetworkPolicy',
    metadata: { name: 'egress-deny', namespace: 'kube-system' },
    spec: {
      podSelector: {},
      policyTypes: ['Egress'],
      egress: [
        {
          to: [{ ipBlock: { cidr: '0.0.0.0/0', except: ['100.64.0.0/10', '172.17.0.0/16'] } }],
        },
      ],
    },
  });
});

test('it creates the egress deny in a namespace it creates itself', async () => {
  const stub = buildStubResourceMocks();

  await runtime.setMocks(stub.mocks, 'geoff-cloud', 'test');

  onTestFinished(() => {
    stub.release();
    runtime.resetOptions('', '', -1, '', '', false, '');
  });

  createCluster(createClusterProvider('k3s', { kubeconfig: output('kubeconfig-for-tests') }), {
    onePasswordConnect: { credentials: output('{}') },
    zoneID: output('zone'),
  });

  await stub.whenRegistered(
    'kubernetes:networking.k8s.io/v1:NetworkPolicy::onepassword-egress-deny',
  );

  expect(
    stub.inputs.get('kubernetes:networking.k8s.io/v1:NetworkPolicy::onepassword-egress-deny'),
  ).toStrictEqual({
    apiVersion: 'networking.k8s.io/v1',
    kind: 'NetworkPolicy',
    metadata: { name: 'egress-deny', namespace: 'onepassword' },
    spec: {
      podSelector: {},
      policyTypes: ['Egress'],
      egress: [
        {
          to: [{ ipBlock: { cidr: '0.0.0.0/0', except: ['100.64.0.0/10', '172.17.0.0/16'] } }],
        },
      ],
    },
  });
});

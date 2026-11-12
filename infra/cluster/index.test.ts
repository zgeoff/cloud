import { expect, onTestFinished, test } from 'bun:test';
import { output, runtime, secret } from '@pulumi/pulumi';
import { z } from 'zod';
import type { BoxxyRepos } from '../inputs/index.ts';
import { buildMockATCGatewayConfig } from '../test-utils/build-mock-atc-gateway-config.ts';
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
    createClusterProvider('k3s', {
      kubeconfig: output('kubeconfig-for-tests'),
    }),
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
        tokenHashes: {
          agent: output('a'.repeat(64)),
          owner: output('b'.repeat(64)),
        },
      },
      zoneID: output('zone'),
      kubeconfig: output('kubeconfig-for-tests'),
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
    createClusterProvider('k3s', {
      kubeconfig: output('kubeconfig-for-tests'),
    }),
    {
      onePasswordConnect: { credentials: output('{}') },
      zoneID: output('zone'),
      kubeconfig: output('kubeconfig-for-tests'),
    },
  );

  expect(workloads.filesRoute).toBeUndefined();
});

test("it returns the boxxy server's owner Service and pins only the worker Service, when boxxy is set", async () => {
  const boxxyInputs = {
    config: {
      image:
        'ghcr.io/zgeoff/cloud-boxxy:0123456@sha256:4444444444444444444444444444444444444444444444444444444444444444',
      runner: 'runner-for-tests',
      atc: { trustedFolders: {} },
      spawn: { target: 'target-for-tests' },
    },
    repos: secret<BoxxyRepos>({
      'owner/repo': { url: 'https://github.com/owner/repo', ref: 'main' },
    }),
    pullCredential: {
      username: 'octo-puller',
      token: output('ghp_fake0token0for0tests0only0000000000'),
    },
    secrets: {
      workerToken: output('worker-token-for-tests'),
      atcToken: output('atc-token-for-tests'),
    },
  };

  const gatewayConfig = buildMockATCGatewayConfig();
  const stub = buildStubResourceMocks();

  await runtime.setMocks(stub.mocks, 'geoff-cloud', 'test');

  onTestFinished(() => {
    stub.release();
    runtime.resetOptions('', '', -1, '', '', false, '');
  });

  const workloads = createCluster(
    createClusterProvider('k3s', {
      kubeconfig: output('kubeconfig-for-tests'),
    }),
    {
      onePasswordConnect: { credentials: output('{}') },
      atcGateway: {
        inputs: {
          config: gatewayConfig,
          secrets: {
            pullCredential: {
              username: 'octo-puller',
              token: output('ghp_fake0token0for0tests0only0000000000'),
            },
            tokens: { geoffcloud: output('daemon-token-for-tests') },
            ownerEmail: output('owner@fixture.invalid'),
          },
        },
        tunnelToken: output('tunnel-token-for-tests'),
      },
      boxxy: boxxyInputs,
      zoneID: output('zone'),
      kubeconfig: output('kubeconfig-for-tests'),
    },
  );

  if (workloads.boxxyServiceURL === undefined) {
    throw new Error('the cluster returned no boxxy Service');
  }

  const service = await resolveOutput(workloads.boxxyServiceURL);

  await stub.whenRegistered('kubernetes:core/v1:Service::boxxy-worker');
  await stub.whenRegistered('kubernetes:core/v1:Service::boxxy');
  await stub.whenRegistered('kubernetes:core/v1:ConfigMap::boxxy-config');

  // the repos are a secret, so Pulumi registers the data as one, which it hides in a preview
  const secretData = z.object({
    [runtime.specialSigKey]: z.literal(runtime.specialSecretSig),
    value: z.object({ 'config.json': z.string() }),
  });

  const config = z
    .object({ data: secretData })
    .parse(stub.inputs.get('kubernetes:core/v1:ConfigMap::boxxy-config'));

  expect(service).toBe('http://boxxy.boxxy.svc.cluster.local:8090');

  expect(JSON.parse(config.data.value['config.json'])).toMatchObject({
    spawn: {
      target: 'target-for-tests',
      repos: { 'owner/repo': { url: 'https://github.com/owner/repo', ref: 'main' } },
    },
    atc: {
      url: 'http://atc-gateway.atc.svc.cluster.local:8414/mcp',
      host: new URL(gatewayConfig.publicURL).host,
      trustedFolders: {},
    },
  });

  expect(stub.inputs.get('kubernetes:core/v1:Service::boxxy-worker')?.['spec']).toStrictEqual({
    clusterIP: '10.43.0.80',
    selector: { app: 'boxxy-server' },
    ports: [{ name: 'worker', port: 8091, targetPort: 'worker' }],
  });

  expect(stub.inputs.get('kubernetes:core/v1:Service::boxxy')?.['spec']).toStrictEqual({
    selector: { app: 'boxxy-server' },
    ports: [{ name: 'owner', port: 8090, targetPort: 'owner' }],
  });
});

test("it writes the gateway's service token Secret, with the public URL's /mcp as its resource, and passes the file to the gateway, while a service token is set", async () => {
  const token = `atcs_${'c'.repeat(40)}`;
  const stub = buildStubResourceMocks();

  await runtime.setMocks(stub.mocks, 'geoff-cloud', 'test');

  onTestFinished(() => {
    stub.release();
    runtime.resetOptions('', '', -1, '', '', false, '');
  });

  createCluster(createClusterProvider('k3s', { kubeconfig: output('kubeconfig-for-tests') }), {
    onePasswordConnect: { credentials: output('{}') },
    atcGateway: {
      inputs: {
        config: buildMockATCGatewayConfig({ publicURL: 'https://atc.geoff.cloud' }),
        secrets: {
          pullCredential: {
            username: 'octo-puller',
            token: output('ghp_fake0token0for0tests0only0000000000'),
          },
          tokens: { geoffcloud: output('daemon-token-for-tests') },
          ownerEmail: output('owner@fixture.invalid'),
          serviceTokens: { boxxy: output(token) },
        },
      },
      tunnelToken: output('tunnel-token-for-tests'),
    },
    zoneID: output('zone'),
    kubeconfig: output('kubeconfig-for-tests'),
  });

  await stub.whenRegistered('kubernetes:apps/v1:Deployment::atc-gateway');
  await stub.whenRegistered('kubernetes:core/v1:Secret::atc-gateway-service-tokens');

  // the mock keeps a secret value under `value`, beside Pulumi's secret signature
  const tokenFile = z.object({ 'service-tokens.json': z.string() });

  const tokenSecret = z
    .object({
      metadata: z.object({ name: z.string().optional() }),
      stringData: z.object({ value: tokenFile }),
    })
    .parse(stub.inputs.get('kubernetes:core/v1:Secret::atc-gateway-service-tokens'));

  const registered = stub.inputs.get('kubernetes:apps/v1:Deployment::atc-gateway');
  const deployment = JSON.stringify(registered);

  expect(tokenSecret.metadata.name).toBeUndefined();

  expect(JSON.parse(tokenSecret.stringData.value['service-tokens.json'])).toStrictEqual({
    resource: 'https://atc.geoff.cloud/mcp',
    clients: { boxxy: { scopes: ['read', 'spawn', 'message', 'kill'], tokens: [token] } },
  });

  expect(deployment).toContain('--service-token-file');
});

test('it writes no service token Secret and passes no flag to the gateway while no service token is set', async () => {
  const stub = buildStubResourceMocks();

  await runtime.setMocks(stub.mocks, 'geoff-cloud', 'test');

  onTestFinished(() => {
    stub.release();
    runtime.resetOptions('', '', -1, '', '', false, '');
  });

  createCluster(createClusterProvider('k3s', { kubeconfig: output('kubeconfig-for-tests') }), {
    onePasswordConnect: { credentials: output('{}') },
    atcGateway: {
      inputs: {
        config: buildMockATCGatewayConfig({ publicURL: 'https://atc.geoff.cloud' }),
        secrets: {
          pullCredential: {
            username: 'octo-puller',
            token: output('ghp_fake0token0for0tests0only0000000000'),
          },
          tokens: { geoffcloud: output('daemon-token-for-tests') },
          ownerEmail: output('owner@fixture.invalid'),
        },
      },
      tunnelToken: output('tunnel-token-for-tests'),
    },
    zoneID: output('zone'),
    kubeconfig: output('kubeconfig-for-tests'),
  });

  await stub.whenRegistered('kubernetes:apps/v1:Deployment::atc-gateway');

  const registered = stub.inputs.get('kubernetes:apps/v1:Deployment::atc-gateway');
  const deployment = JSON.stringify(registered);

  expect(stub.registered).not.toContain('kubernetes:core/v1:Secret::atc-gateway-service-tokens');
  expect(deployment).not.toContain('service-token');
});

test('it refuses boxxy without the atc gateway, which the server calls atc through', async () => {
  const stub = buildStubResourceMocks();

  await runtime.setMocks(stub.mocks, 'geoff-cloud', 'test');

  onTestFinished(() => {
    stub.release();
    runtime.resetOptions('', '', -1, '', '', false, '');
  });

  expect(() =>
    createCluster(createClusterProvider('k3s', { kubeconfig: output('kubeconfig-for-tests') }), {
      onePasswordConnect: { credentials: output('{}') },
      boxxy: {
        config: {
          image:
            'ghcr.io/zgeoff/cloud-boxxy:0123456@sha256:4444444444444444444444444444444444444444444444444444444444444444',
          runner: 'runner-for-tests',
          atc: { trustedFolders: {} },
          spawn: { target: 'target-for-tests' },
        },
        repos: secret<BoxxyRepos>({}),
        pullCredential: {
          username: 'octo-puller',
          token: output('ghp_fake0token0for0tests0only0000000000'),
        },
        secrets: {
          workerToken: output('worker-token-for-tests'),
          atcToken: output('atc-token-for-tests'),
        },
      },
      zoneID: output('zone'),
      kubeconfig: output('kubeconfig-for-tests'),
    }),
  ).toThrowWithMessage(
    Error,
    'stack config "boxxy" needs stack config "atcGateway": the boxxy server calls atc through the gateway',
  );
});

test('it creates no boxxy server while boxxy is unset', async () => {
  const stub = buildStubResourceMocks();

  await runtime.setMocks(stub.mocks, 'geoff-cloud', 'test');

  onTestFinished(() => {
    stub.release();
    runtime.resetOptions('', '', -1, '', '', false, '');
  });

  const workloads = createCluster(
    createClusterProvider('k3s', {
      kubeconfig: output('kubeconfig-for-tests'),
    }),
    {
      onePasswordConnect: { credentials: output('{}') },
      zoneID: output('zone'),
      kubeconfig: output('kubeconfig-for-tests'),
    },
  );

  await stub.whenRegistered('kubernetes:core/v1:Namespace::onepassword');

  expect(workloads.boxxyServiceURL).toBeUndefined();
  expect(stub.registered.filter((key) => key.includes('boxxy'))).toBeEmpty();
});

test('it creates the egress deny in each namespace k3s creates, kube-system and default included', async () => {
  const stub = buildStubResourceMocks();

  await runtime.setMocks(stub.mocks, 'geoff-cloud', 'test');

  onTestFinished(() => {
    stub.release();
    runtime.resetOptions('', '', -1, '', '', false, '');
  });

  createCluster(
    createClusterProvider('k3s', {
      kubeconfig: output('kubeconfig-for-tests'),
    }),
    {
      onePasswordConnect: { credentials: output('{}') },
      zoneID: output('zone'),
      kubeconfig: output('kubeconfig-for-tests'),
    },
  );

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
          to: [
            {
              ipBlock: {
                cidr: '0.0.0.0/0',
                except: ['100.64.0.0/10', '10.88.0.0/16'],
              },
            },
          ],
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

  createCluster(
    createClusterProvider('k3s', {
      kubeconfig: output('kubeconfig-for-tests'),
    }),
    {
      onePasswordConnect: { credentials: output('{}') },
      zoneID: output('zone'),
      kubeconfig: output('kubeconfig-for-tests'),
    },
  );

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
          to: [
            {
              ipBlock: {
                cidr: '0.0.0.0/0',
                except: ['100.64.0.0/10', '10.88.0.0/16'],
              },
            },
          ],
        },
      ],
    },
  });
});

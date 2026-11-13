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

test("it refuses boxxy's pepys section without pepys in the cluster, which gets its facts", async () => {
  const stub = buildStubResourceMocks();

  await runtime.setMocks(stub.mocks, 'geoff-cloud', 'test');

  onTestFinished(() => {
    stub.release();
    runtime.resetOptions('', '', -1, '', '', false, '');
  });

  expect(() =>
    createCluster(createClusterProvider('k3s', { kubeconfig: output('kubeconfig-for-tests') }), {
      onePasswordConnect: { credentials: output('{}') },
      atcGateway: {
        inputs: {
          config: buildMockATCGatewayConfig(),
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
      boxxy: {
        config: {
          image:
            'ghcr.io/zgeoff/cloud-boxxy:0123456@sha256:4444444444444444444444444444444444444444444444444444444444444444',
          runner: 'runner-for-tests',
          atc: { trustedFolders: {} },
          spawn: { target: 'target-for-tests' },
          pepys: { environment: 'production' },
        },
        repos: secret<BoxxyRepos>({}),
        pullCredential: {
          username: 'octo-puller',
          token: output('ghp_fake0token0for0tests0only0000000000'),
        },
        secrets: {
          workerToken: output('worker-token-for-tests'),
          atcToken: output('atc-token-for-tests'),
          pepysSigningSecret: output('signing-secret-for-tests'),
        },
      },
      zoneID: output('zone'),
      kubeconfig: output('kubeconfig-for-tests'),
    }),
  ).toThrowWithMessage(
    Error,
    'stack config "boxxy.pepys" needs stack config "pepys": the boxxy server sends its facts to the pepys in the cluster',
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

test("it puts the door tunnel's token in a Secret of the boxxy namespace and gives it to the server's pod alone, when boxxy has a public door", async () => {
  const boxxyInputs = {
    config: {
      image:
        'ghcr.io/zgeoff/cloud-boxxy:0123456@sha256:4444444444444444444444444444444444444444444444444444444444444444',
      runner: 'runner-for-tests',
      atc: { trustedFolders: {} },
      spawn: { target: 'target-for-tests' },
      publicDoor: { publicURL: 'https://boxxy.example.com', trustForwardedFrom: ['127.0.0.1'] },
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
  };

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
        config: buildMockATCGatewayConfig({
          daemons: { 'daemon-a': {} },
          defaultDaemon: 'daemon-a',
        }),
        secrets: {
          pullCredential: {
            username: 'octo-puller',
            token: output('ghp_fake0token0for0tests0only0000000000'),
          },
          tokens: { 'daemon-a': output('daemon-token-for-tests') },
          ownerEmail: output('owner@fixture.invalid'),
        },
      },
      tunnelToken: output('tunnel-token-for-tests'),
    },
    boxxy: boxxyInputs,
    boxxyDoorTunnelToken: output('door-tunnel-token-for-tests'),
    zoneID: output('zone'),
    kubeconfig: output('kubeconfig-for-tests'),
  });

  await stub.whenRegistered('kubernetes:apps/v1:StatefulSet::boxxy');

  const volume = z.object({ name: z.string(), secret: z.unknown().optional() });
  const container = z.object({ name: z.string() });
  const podSpec = z.object({ containers: z.array(container), volumes: z.array(volume) });
  const template = z.object({ spec: podSpec });

  const statefulSet = z
    .object({ spec: z.object({ template }) })
    .parse(stub.inputs.get('kubernetes:apps/v1:StatefulSet::boxxy'));

  expect({
    secret: stub.inputs.get('kubernetes:core/v1:Secret::boxxy-door-tunnel-token'),
    containers: statefulSet.spec.template.spec.containers.map((entry) => entry.name),
    tunnelVolume: statefulSet.spec.template.spec.volumes.find(
      (candidate) => candidate.name === 'tunnel-token',
    ),
  }).toStrictEqual({
    secret: {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: { namespace: 'boxxy' },

      // Pulumi registers a Secret's data as a secret, which it hides in a preview
      stringData: {
        [runtime.specialSigKey]: runtime.specialSecretSig,
        value: { token: 'door-tunnel-token-for-tests' },
      },
    },
    containers: ['boxxy', 'cloudflared'],

    // the mock leaves the Secret's generated name unknown, so the volume carries no name yet
    tunnelVolume: { name: 'tunnel-token', secret: { defaultMode: 0o440 } },
  });
});

test("it refuses boxxy's public door without the door tunnel's token", async () => {
  const stub = buildStubResourceMocks();

  await runtime.setMocks(stub.mocks, 'geoff-cloud', 'test');

  onTestFinished(() => {
    stub.release();
    runtime.resetOptions('', '', -1, '', '', false, '');
  });

  expect(() =>
    createCluster(createClusterProvider('k3s', { kubeconfig: output('kubeconfig-for-tests') }), {
      onePasswordConnect: { credentials: output('{}') },
      atcGateway: {
        inputs: {
          config: buildMockATCGatewayConfig({
            daemons: { 'daemon-a': {} },
            defaultDaemon: 'daemon-a',
          }),
          secrets: {
            pullCredential: {
              username: 'octo-puller',
              token: output('ghp_fake0token0for0tests0only0000000000'),
            },
            tokens: { 'daemon-a': output('daemon-token-for-tests') },
            ownerEmail: output('owner@fixture.invalid'),
          },
        },
        tunnelToken: output('tunnel-token-for-tests'),
      },
      boxxy: {
        config: {
          image:
            'ghcr.io/zgeoff/cloud-boxxy:0123456@sha256:4444444444444444444444444444444444444444444444444444444444444444',
          runner: 'runner-for-tests',
          atc: { trustedFolders: {} },
          spawn: { target: 'target-for-tests' },
          publicDoor: { publicURL: 'https://boxxy.example.com', trustForwardedFrom: [] },
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
  ).toThrowWithMessage(Error, "the boxxy server's public door has no tunnel token");
});

test("it refuses pepys's tailnet hostname without nixie, whose Traefik carries the route", async () => {
  const stub = buildStubResourceMocks();

  await runtime.setMocks(stub.mocks, 'geoff-cloud', 'test');

  onTestFinished(() => {
    stub.release();
    runtime.resetOptions('', '', -1, '', '', false, '');
  });

  expect(() =>
    createCluster(createClusterProvider('k3s', { kubeconfig: output('kubeconfig-for-tests') }), {
      onePasswordConnect: { credentials: output('{}') },
      pepys: {
        config: {
          image:
            'ghcr.io/zgeoff/cloud-pepys:0.4.0-3f9c1d2a7b10@sha256:4444444444444444444444444444444444444444444444444444444444444444',
          webhookHostname: 'pepys-webhook.geoff.cloud',
          tailnetHostname: 'pepys-api.geoff.cloud',
        },
        pullCredential: {
          username: 'octo-puller',
          token: output('ghp_fake0token0for0tests0only0000000000'),
        },
        secrets: {
          garageRPCSecret: output('rpc-secret-for-tests'),
          garageAdminToken: output('admin-token-for-tests'),
          s2GarageAccessKeyID: output('GK0123456789abcdef01234567'),
          s2GarageSecretAccessKey: output('s2-garage-secret-for-tests'),
          s2AccessToken: output('s2-token-for-tests'),
          ingest: {},
        },
      },
      zoneID: output('zone'),
      kubeconfig: output('kubeconfig-for-tests'),
    }),
  ).toThrowWithMessage(
    Error,
    'stack config "pepys.tailnetHostname" needs stack config "nixie": the route goes through nixie\'s Traefik',
  );
});

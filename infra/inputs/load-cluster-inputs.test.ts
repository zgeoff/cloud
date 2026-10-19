import { expect, test } from 'bun:test';
import { Output, isSecret } from '@pulumi/pulumi';
import invariant from 'tiny-invariant';
import { buildMockATCGatewayConfig } from '../test-utils/build-mock-atc-gateway-config.ts';
import { buildStubConfig } from '../test-utils/build-stub-config.ts';
import { resolveOutput } from '../test-utils/resolve-output.ts';
import { loadClusterInputs } from './load-cluster-inputs.ts';

test('it returns nothing when the stack config leaves the cluster out', () => {
  expect(
    loadClusterInputs(buildStubConfig({ cluster: 'none' }), {
      K3S_KUBECONFIG: 'apiVersion: v1',
      ONEPASSWORD_CONNECT_CREDENTIALS: '{"verifier":{}}',
    }),
  ).toBeUndefined();
});

test("it throws when the stack config's cluster is unset", () => {
  expect(() =>
    loadClusterInputs(buildStubConfig({}), {
      K3S_KUBECONFIG: 'apiVersion: v1',
      ONEPASSWORD_CONNECT_CREDENTIALS: '{"verifier":{}}',
    }),
  ).toThrowWithMessage(Error, 'stack config "cluster" is unset; set it to managed or none');
});

test('it returns the kubeconfig and the Connect credentials, and no gateway while atcGateway is unset, for a managed cluster', () => {
  expect(
    loadClusterInputs(buildStubConfig({ cluster: 'managed' }), {
      K3S_KUBECONFIG: 'apiVersion: v1',
      ONEPASSWORD_CONNECT_CREDENTIALS: '{"verifier":{}}',
    }),
  ).toStrictEqual({
    kubeconfig: 'apiVersion: v1',
    onePasswordConnectCredentials: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
  });
});

test('it marks the Connect credentials secret', () => {
  const inputs = loadClusterInputs(buildStubConfig({ cluster: 'managed' }), {
    K3S_KUBECONFIG: 'apiVersion: v1',
    ONEPASSWORD_CONNECT_CREDENTIALS: '{"verifier":{}}',
  });

  invariant(inputs !== undefined, 'expected the cluster inputs');

  expect(isSecret(inputs.onePasswordConnectCredentials)).resolves.toBeTrue();
});

test('it carries the Connect credentials file as given', () => {
  const inputs = loadClusterInputs(buildStubConfig({ cluster: 'managed' }), {
    K3S_KUBECONFIG: 'apiVersion: v1',
    ONEPASSWORD_CONNECT_CREDENTIALS: '{"verifier":{}}',
  });

  invariant(inputs !== undefined, 'expected the cluster inputs');

  expect(resolveOutput(inputs.onePasswordConnectCredentials)).resolves.toBe('{"verifier":{}}');
});

test('it loads the gateway from the same stack config and environment when atcGateway is set', () => {
  const config = buildMockATCGatewayConfig({
    daemons: {
      geoffcloud: {
        address: '100.69.47.33:8415',
        daemonID: '0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d',
        alertSeverity: 'critical',
      },
    },
    defaultDaemon: 'geoffcloud',
  });

  const stackConfig = buildStubConfig({
    cluster: 'managed',
    atcGateway: JSON.stringify(config),
    atcGatewayOwnerEmail: 'owner@example.test',
  });

  expect(
    loadClusterInputs(stackConfig, {
      K3S_KUBECONFIG: 'apiVersion: v1',
      ONEPASSWORD_CONNECT_CREDENTIALS: '{"verifier":{}}',
      ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
      GHCR_PULL_USERNAME: 'octo-puller',
      GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
    }),
  ).toStrictEqual({
    kubeconfig: 'apiVersion: v1',
    onePasswordConnectCredentials: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
    atcGateway: {
      config,
      secrets: {
        pullCredential: {
          username: 'octo-puller',
          token: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
        },
        tokens: { geoffcloud: expect.toSatisfy((value: unknown) => Output.isInstance(value)) },
        ownerEmail: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
      },
    },
  });
});

test('it checks the Connect credentials before the gateway, so a missing file fails first', () => {
  expect(() =>
    loadClusterInputs(buildStubConfig({ cluster: 'managed', atcGateway: '{"image":"atc"}' }), {
      K3S_KUBECONFIG: 'apiVersion: v1',
    }),
  ).toThrowWithMessage(
    Error,
    'cluster is managed, but ONEPASSWORD_CONNECT_CREDENTIALS is empty; run through `op run --env-file=../.env`',
  );
});

test("it runs nixie's backup in the gateway's backup image, pulled with the gateway's credential", () => {
  const config = buildMockATCGatewayConfig({
    backupImage:
      'ghcr.io/zgeoff/atc-gateway-backup:4.0.0-r1@sha256:2222222222222222222222222222222222222222222222222222222222222222',
    daemons: { geoffcloud: {} },
    defaultDaemon: 'geoffcloud',
  });

  const inputs = loadClusterInputs(
    buildStubConfig({
      cluster: 'managed',
      atcGateway: JSON.stringify(config),
      atcGatewayOwnerEmail: 'owner@example.test',
      nixie: JSON.stringify({
        image:
          'ghcr.io/zgeoff/nixie:0.1.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
        webImage:
          'ghcr.io/zgeoff/nixie-web:0.1.0@sha256:318c0b6c6ff89e0b0bbd252df2d04b0120ef28c7266d698ffa9757ff4d2f5754',
        hostname: 'nixie.geoff.cloud',
      }),
    }),
    {
      K3S_KUBECONFIG: 'apiVersion: v1',
      ONEPASSWORD_CONNECT_CREDENTIALS: '{"verifier":{}}',
      ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
      GHCR_PULL_USERNAME: 'octo-puller',
      GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
      NIXIE_AGE_HOST_KEY: 'AGE-SECRET-KEY-1QQQ',
      NIXIE_DEFINITIONS_DEPLOY_KEY: 'deploy-key',
      CLOUDFLARE_API_TOKEN: 'cf-token',
      NIXIE_RESTIC_PASSWORD: 'p'.repeat(32),
      NIXIE_R2_ACCESS_KEY_ID: 'a'.repeat(32),
      NIXIE_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
      NIXIE_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
      NIXIE_R2_BUCKET: 'nixie-backups',
    },
  );

  expect(inputs?.atcGateway?.secrets.pullCredential).toStrictEqual({
    username: 'octo-puller',
    token: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
  });

  expect(inputs?.nixie?.backup?.pullCredential).toBe(inputs?.atcGateway?.secrets.pullCredential);

  expect(inputs?.nixie?.backup?.image).toBe(
    'ghcr.io/zgeoff/atc-gateway-backup:4.0.0-r1@sha256:2222222222222222222222222222222222222222222222222222222222222222',
  );
});

test("it runs the files service's backup in the gateway's backup image", () => {
  const config = buildMockATCGatewayConfig({
    backupImage:
      'ghcr.io/zgeoff/atc-gateway-backup:4.0.0-r1@sha256:2222222222222222222222222222222222222222222222222222222222222222',
    daemons: { geoffcloud: {} },
    defaultDaemon: 'geoffcloud',
  });

  const inputs = loadClusterInputs(
    buildStubConfig({
      cluster: 'managed',
      atcGateway: JSON.stringify(config),
      atcGatewayOwnerEmail: 'owner@example.test',
      files: JSON.stringify({
        image:
          'ghcr.io/zgeoff/cloud-files:0123456@sha256:3333333333333333333333333333333333333333333333333333333333333333',
        hostname: 'files.geoff.cloud',
      }),
    }),
    {
      K3S_KUBECONFIG: 'apiVersion: v1',
      ONEPASSWORD_CONNECT_CREDENTIALS: '{"verifier":{}}',
      ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
      GHCR_PULL_USERNAME: 'octo-puller',
      GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
      FILES_AGENT_TOKEN: 'agent-token-for-tests',
      FILES_OWNER_TOKEN: 'owner-token-for-tests',
      FILES_RESTIC_PASSWORD: 'p'.repeat(32),
      FILES_R2_ACCESS_KEY_ID: 'a'.repeat(32),
      FILES_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
      FILES_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
      FILES_R2_BUCKET: 'backups',
    },
  );

  expect(inputs?.files?.backup?.image).toBe(
    'ghcr.io/zgeoff/atc-gateway-backup:4.0.0-r1@sha256:2222222222222222222222222222222222222222222222222222222222222222',
  );
});

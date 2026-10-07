import { expect, test } from 'bun:test';
import { Output, isSecret } from '@pulumi/pulumi';
import { loadClusterInputs } from './load-cluster-inputs.ts';
import { buildMockATCGatewayConfig } from './test-utils/build-mock-atc-gateway-config.ts';
import { buildStubConfig } from './test-utils/build-stub-config.ts';
import { readOutput } from './test-utils/read-output.ts';

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

  if (inputs === undefined) {
    throw new Error('expected the cluster inputs');
  }

  expect(isSecret(inputs.onePasswordConnectCredentials)).resolves.toBeTrue();
});

test('it carries the Connect credentials file as given', () => {
  const inputs = loadClusterInputs(buildStubConfig({ cluster: 'managed' }), {
    K3S_KUBECONFIG: 'apiVersion: v1',
    ONEPASSWORD_CONNECT_CREDENTIALS: '{"verifier":{}}',
  });

  if (inputs === undefined) {
    throw new Error('expected the cluster inputs');
  }

  expect(readOutput(inputs.onePasswordConnectCredentials)).resolves.toBe('{"verifier":{}}');
});

test('it loads the gateway from the same stack config and environment when atcGateway is set', () => {
  const config = buildMockATCGatewayConfig({
    daemons: {
      geoffcloud: {
        address: '100.69.47.33:8415',
        daemonID: '0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d',
      },
    },
    defaultDaemon: 'geoffcloud',
  });

  const stackConfig = buildStubConfig({ cluster: 'managed', atcGateway: JSON.stringify(config) });

  expect(
    loadClusterInputs(stackConfig, {
      K3S_KUBECONFIG: 'apiVersion: v1',
      ONEPASSWORD_CONNECT_CREDENTIALS: '{"verifier":{}}',
      ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
    }),
  ).toStrictEqual({
    kubeconfig: 'apiVersion: v1',
    onePasswordConnectCredentials: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
    atcGateway: {
      config,
      daemons: {
        geoffcloud: {
          address: '100.69.47.33:8415',
          daemonID: '0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d',
          alertSeverity: 'critical',
        },
      },
      defaultDaemon: 'geoffcloud',
      secrets: {
        tokens: { geoffcloud: expect.toSatisfy((value: unknown) => Output.isInstance(value)) },
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

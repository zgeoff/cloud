import { expect, test } from 'bun:test';
import { buildStubKubectlToken } from './build-stub-kubectl-token.ts';
import { buildStubRunner } from './build-stub-runner.ts';

test('it mints a token whose expiry is the asked duration after the clock', async () => {
  const kubectl = buildStubKubectlToken({
    adminKubeconfig: '/case/admin.yaml',
    server: 'https://cluster.example.test:6443',
    certificateAuthorityData: 'Y2EtZm9yLXRlc3Rz',
    token: 'fake-token-for-tests',
    nowMs: Date.parse('2026-11-15T06:00:00Z'),
  });

  const runner = buildStubRunner(kubectl.handler);

  const result = await runner.run([
    'kubectl',
    '--kubeconfig',
    '/case/admin.yaml',
    '--namespace',
    'nixie',
    'create',
    'token',
    'nixie-verify',
    '--duration=2160h',
    '--output',
    'json',
  ]);

  expect(JSON.parse(result.stdout.toString())).toMatchObject({
    status: { token: 'fake-token-for-tests', expirationTimestamp: '2027-02-13T06:00:00Z' },
  });
});

test('it refuses a token for an account the cluster lacks, as kubectl does', async () => {
  const kubectl = buildStubKubectlToken({
    adminKubeconfig: '/case/admin.yaml',
    server: 'https://cluster.example.test:6443',
    certificateAuthorityData: 'Y2EtZm9yLXRlc3Rz',
    nowMs: Date.parse('2026-11-15T06:00:00Z'),
  });

  const runner = buildStubRunner(kubectl.handler);

  const result = await runner.run([
    'kubectl',
    '--kubeconfig',
    '/case/admin.yaml',
    '--namespace',
    'nixie',
    'create',
    'token',
    'nixie-verify',
    '--duration=10m',
    '--output',
    'json',
  ]);

  expect({ exitCode: result.exitCode, stderr: result.stderr.toString() }).toStrictEqual({
    exitCode: 1,
    stderr: 'error: failed to create token: serviceaccounts "nixie-verify" not found\n',
  });
});

test('it leaves a call that names another kubeconfig to the next handler', async () => {
  const kubectl = buildStubKubectlToken({
    adminKubeconfig: '/case/admin.yaml',
    server: 'https://cluster.example.test:6443',
    certificateAuthorityData: 'Y2EtZm9yLXRlc3Rz',
    token: 'fake-token-for-tests',
    nowMs: Date.parse('2026-11-15T06:00:00Z'),
  });

  const runner = buildStubRunner(kubectl.handler);

  const result = await runner.run(['kubectl', '--kubeconfig', '/case/other.yaml', 'version']);

  expect(result.exitCode).toBe(97);
});

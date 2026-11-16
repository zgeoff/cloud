import { expect, mock, onTestFinished, test } from 'bun:test';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { findJSONField } from './find-json-field.ts';
import type { Runner } from './run-process.ts';
import { buildStubKubectlToken } from './test-utils/build-stub-kubectl-token.ts';
import { buildStubOp } from './test-utils/build-stub-op.ts';
import type { StubHandler } from './test-utils/build-stub-runner.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';
import { writeNixieVerifyKubeconfig } from './write-nixie-verify-kubeconfig.ts';

async function setupTest() {
  const workDir = await mkdtemp(join(tmpdir(), 'write-nixie-verify-kubeconfig-'));

  onTestFinished(() => rm(workDir, { recursive: true, force: true }));

  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  return {
    adminKubeconfig: join(workDir, 'admin-kubeconfig.yaml'),
    printOut,
    printErr,
    write: (run: Runner) => writeNixieVerifyKubeconfig({ run, workDir, printOut, printErr }),
  };
}

test('it stores a kubeconfig with a 90-day nixie-verify token as a new document, and prints only its expiry', async () => {
  const ctx = await setupTest();

  const op = buildStubOp({
    vaults: { cloud: { 'k3s-kubeconfig': 'apiVersion: v1\nkind: Config\n' }, nixie: {} },
  });

  const kubectl = buildStubKubectlToken({
    adminKubeconfig: ctx.adminKubeconfig,
    server: 'https://cluster.example.test:6443',
    certificateAuthorityData: 'Y2EtZm9yLXRlc3Rz',
    token: 'fake-token-for-tests',
    nowMs: Date.parse('2026-11-15T06:00:00Z'),
  });

  const runner = buildStubRunner(op.answer, kubectl.handler);

  const exitCode = await ctx.write(runner.run);

  expect({
    exitCode,
    out: ctx.printOut.mock.calls,
    err: ctx.printErr.mock.calls,
    durations: kubectl.durations,
  }).toStrictEqual({
    exitCode: 0,
    out: [
      [
        'stored op://nixie/nixie-prod-kubeconfig/kubeconfig.yaml; its nixie-verify token expires at 2027-02-13T06:00:00Z\n',
      ],
    ],
    err: [],
    durations: ['2160h'],
  });

  const stored = Bun.YAML.parse(op.vaults['nixie']?.['nixie-prod-kubeconfig'] ?? '');

  expect({
    clusters: findJSONField(stored, 'clusters'),
    users: findJSONField(stored, 'users'),
  }).toStrictEqual({
    clusters: [
      {
        name: 'geoff-cloud',
        cluster: {
          server: 'https://cluster.example.test:6443',
          'certificate-authority-data': 'Y2EtZm9yLXRlc3Rz',
        },
      },
    ],
    users: [{ name: 'nixie-verify', user: { token: 'fake-token-for-tests' } }],
  });
});

test('it replaces the file of the document when the item exists', async () => {
  const ctx = await setupTest();

  const op = buildStubOp({
    vaults: {
      cloud: { 'k3s-kubeconfig': 'apiVersion: v1\nkind: Config\n' },
      nixie: { 'nixie-prod-kubeconfig': 'an older kubeconfig\n' },
    },
  });

  const kubectl = buildStubKubectlToken({
    adminKubeconfig: ctx.adminKubeconfig,
    server: 'https://cluster.example.test:6443',
    certificateAuthorityData: 'Y2EtZm9yLXRlc3Rz',
    token: 'fake-token-for-tests',
    nowMs: Date.parse('2026-11-15T06:00:00Z'),
  });

  const runner = buildStubRunner(op.answer, kubectl.handler);

  await ctx.write(runner.run);

  expect(
    runner.calls.filter((call) => call.argv[1] === 'document').map((call) => call.argv),
  ).toStrictEqual([
    [
      'op',
      'document',
      'edit',
      'nixie-prod-kubeconfig',
      '--vault',
      'nixie',
      '--file-name',
      'kubeconfig.yaml',
      '-',
    ],
  ]);
});

test('it sends the token only on stdin, and removes the admin kubeconfig it wrote', async () => {
  const ctx = await setupTest();

  const op = buildStubOp({
    vaults: { cloud: { 'k3s-kubeconfig': 'apiVersion: v1\nkind: Config\n' }, nixie: {} },
  });

  const kubectl = buildStubKubectlToken({
    adminKubeconfig: ctx.adminKubeconfig,
    server: 'https://cluster.example.test:6443',
    certificateAuthorityData: 'Y2EtZm9yLXRlc3Rz',
    token: 'fake-token-for-tests',
    nowMs: Date.parse('2026-11-15T06:00:00Z'),
  });

  const admins: { readonly mode: number; readonly text: string }[] = [];

  // the admin kubeconfig as each kubectl call found it; the call goes on to the next handler
  const recordAdmin: StubHandler = (call) => {
    if (call.argv[0] === 'kubectl') {
      admins.push({
        mode: statSync(ctx.adminKubeconfig).mode % 0o1000,
        text: readFileSync(ctx.adminKubeconfig, 'utf8'),
      });
    }

    return kubectl.handler(call);
  };

  const runner = buildStubRunner(op.answer, recordAdmin);

  await ctx.write(runner.run);

  expect({
    admins,
    argvs: runner.calls.filter((call) => call.argv.join(' ').includes('fake-token-for-tests')),
    stdins: runner.calls
      .filter((call) => call.stdin.includes('fake-token-for-tests'))
      .map((call) => call.argv[2]),
    admin: existsSync(ctx.adminKubeconfig),
  }).toStrictEqual({
    admins: [
      { mode: 0o600, text: 'apiVersion: v1\nkind: Config\n' },
      { mode: 0o600, text: 'apiVersion: v1\nkind: Config\n' },
    ],
    argvs: [],
    stdins: ['create'],
    admin: false,
  });
});

test('it stores nothing when kubectl mints no token', async () => {
  const ctx = await setupTest();

  const op = buildStubOp({
    vaults: { cloud: { 'k3s-kubeconfig': 'apiVersion: v1\nkind: Config\n' }, nixie: {} },
  });

  const kubectl = buildStubKubectlToken({
    adminKubeconfig: ctx.adminKubeconfig,
    server: 'https://cluster.example.test:6443',
    certificateAuthorityData: 'Y2EtZm9yLXRlc3Rz',
    nowMs: Date.parse('2026-11-15T06:00:00Z'),
  });

  const runner = buildStubRunner(op.answer, kubectl.handler);

  const exitCode = await ctx.write(runner.run);

  expect({ exitCode, err: ctx.printErr.mock.calls, nixie: op.vaults['nixie'] }).toStrictEqual({
    exitCode: 1,
    err: [
      [
        'write-nixie-verify-kubeconfig: kubectl minted no token for nixie-verify (exit 1): error: failed to create token: serviceaccounts "nixie-verify" not found\n',
      ],
    ],
    nixie: {},
  });
});

test('it fails before kubectl runs when op cannot read the admin kubeconfig', async () => {
  const ctx = await setupTest();

  const op = buildStubOp({ vaults: { cloud: {}, nixie: {} } });
  const runner = buildStubRunner(op.answer);

  const exitCode = await ctx.write(runner.run);

  expect({ exitCode, err: ctx.printErr.mock.calls, calls: runner.calls.length }).toStrictEqual({
    exitCode: 1,
    err: [
      [
        'write-nixie-verify-kubeconfig: could not read op://cloud/k3s-kubeconfig/kubeconfig.yaml: [ERROR] 2026/10/07 12:00:00 could not read secret op://cloud/k3s-kubeconfig: could not get item cloud/k3s-kubeconfig: "k3s-kubeconfig" isn\'t an item in the "cloud" vault.\n',
      ],
    ],
    calls: 1,
  });
});

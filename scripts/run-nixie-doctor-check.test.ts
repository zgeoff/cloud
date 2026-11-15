import { expect, mock, onTestFinished, test } from 'bun:test';
import { existsSync } from 'node:fs';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { findJSONField } from './find-json-field.ts';
import { runNixieDoctorCheck } from './run-nixie-doctor-check.ts';
import type { Runner } from './run-process.ts';
import { buildStubKubectlToken } from './test-utils/build-stub-kubectl-token.ts';
import { buildStubNixieCheckout } from './test-utils/build-stub-nixie-checkout.ts';
import type { StubCall } from './test-utils/build-stub-runner.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'run-nixie-doctor-check-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const stackConfigPath = join(directory, 'Pulumi.prod.yaml');
  const workDir = join(directory, 'work');
  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  return {
    stackConfigPath,
    workDir,
    printOut,
    printErr,
    check: (run: Runner) =>
      runNixieDoctorCheck({
        run,
        stackConfigPath,
        adminKubeconfig: '/runner/k3s-kubeconfig',
        workDir,
        path: '/usr/bin:/bin',
        home: '/runner/home',
        printOut,
        printErr,
      }),
  };
}

test("it runs the pinned release's prod doctor as nixie-verify with a 10-minute token", async () => {
  const ctx = await setupTest();

  await writeFile(
    ctx.stackConfigPath,
    'config:\n  geoff-cloud:nixie:\n    image: ghcr.io/zgeoff/nixie:0.74.0@sha256:456a48906e5ae0c444d84860057ad59e52a90ba485eceb64ea9437474372db6f\n',
  );

  const kubectl = buildStubKubectlToken({
    adminKubeconfig: '/runner/k3s-kubeconfig',
    server: 'https://cluster.example.test:6443',
    certificateAuthorityData: 'Y2EtZm9yLXRlc3Rz',
    token: 'fake-token-for-tests',
    nowMs: Date.parse('2026-11-15T06:00:00Z'),
  });

  const checkout = buildStubNixieCheckout({ doctor: { stdout: '{"ok":true}\n' } });
  const runner = buildStubRunner(kubectl.handler, checkout.handler);

  const exitCode = await ctx.check(runner.run);

  const nixie = join(ctx.workDir, 'nixie');
  const nixieEnv = { PATH: '/usr/bin:/bin', HOME: '/runner/home' };

  const doctorEnv = {
    ...nixieEnv,
    NIXIE_PROD_KUBECONFIG: join(ctx.workDir, 'nixie-verify-kubeconfig.yaml'),
    NIXIE_PROD_VERSION: '0.74.0',
  };

  expect({ exitCode, out: ctx.printOut.mock.calls, err: ctx.printErr.mock.calls }).toStrictEqual({
    exitCode: 0,
    out: [
      ['::add-mask::fake-token-for-tests\n'],
      ['{"ok":true}\n'],
      ['nixie prod doctor passed\n'],
    ],
    err: [],
  });

  expect(
    runner.calls.map((call) => ({ argv: call.argv, cwd: call.options.cwd, env: call.options.env })),
  ).toStrictEqual([
    {
      argv: [
        'git',
        '-c',
        'advice.detachedHead=false',
        'clone',
        '--quiet',
        '--depth',
        '1',
        '--branch',
        'v0.74.0',
        'https://github.com/zgeoff/nixie.git',
        nixie,
      ],
      cwd: undefined,
      env: nixieEnv,
    },
    {
      argv: ['git', '-C', nixie, 'switch', '--quiet', '--create', 'main'],
      cwd: undefined,
      env: nixieEnv,
    },
    {
      argv: ['bun', 'install', '--frozen-lockfile', '--ignore-scripts'],
      cwd: nixie,
      env: nixieEnv,
    },
    {
      argv: [
        'kubectl',
        '--kubeconfig',
        '/runner/k3s-kubeconfig',
        'config',
        'view',
        '--minify',
        '--flatten',
        '--output',
        String.raw`jsonpath={.clusters[0].cluster.server}{"\n"}{.clusters[0].cluster.certificate-authority-data}`,
      ],
      cwd: undefined,
      env: undefined,
    },
    {
      argv: [
        'kubectl',
        '--kubeconfig',
        '/runner/k3s-kubeconfig',
        '--namespace',
        'nixie',
        'create',
        'token',
        'nixie-verify',
        '--duration=10m',
        '--output',
        'json',
      ],
      cwd: undefined,
      env: undefined,
    },
    {
      argv: ['bun', 'run', '--silent', 'verify', 'attach', '--target', 'prod'],
      cwd: nixie,
      env: doctorEnv,
    },
    {
      argv: ['bun', 'run', '--silent', 'verify', 'doctor', '--json', '--target', 'prod'],
      cwd: nixie,
      env: doctorEnv,
    },
    {
      argv: ['bun', 'run', '--silent', 'verify', 'detach', '--target', 'prod'],
      cwd: nixie,
      env: doctorEnv,
    },
  ]);
});

test('it gives the doctor a kubeconfig that only its owner reads, which holds the token, and removes it after', async () => {
  const ctx = await setupTest();

  await writeFile(
    ctx.stackConfigPath,
    'config:\n  geoff-cloud:nixie:\n    image: ghcr.io/zgeoff/nixie:0.74.0@sha256:456a48906e5ae0c444d84860057ad59e52a90ba485eceb64ea9437474372db6f\n',
  );

  const kubectl = buildStubKubectlToken({
    adminKubeconfig: '/runner/k3s-kubeconfig',
    server: 'https://cluster.example.test:6443',
    certificateAuthorityData: 'Y2EtZm9yLXRlc3Rz',
    token: 'fake-token-for-tests',
    nowMs: Date.parse('2026-11-15T06:00:00Z'),
  });

  const checkout = buildStubNixieCheckout({});
  const runner = buildStubRunner(kubectl.handler, checkout.handler);

  await ctx.check(runner.run);

  expect(
    checkout.kubeconfigs.map((read) => ({
      mode: read.mode,
      users: findJSONField(Bun.YAML.parse(read.text), 'users'),
    })),
  ).toStrictEqual([
    { mode: 0o600, users: [{ name: 'nixie-verify', user: { token: 'fake-token-for-tests' } }] },
  ]);

  expect(existsSync(join(ctx.workDir, 'nixie-verify-kubeconfig.yaml'))).toBeFalse();
});

test('it keeps the token out of every argv and every environment', async () => {
  const ctx = await setupTest();

  await writeFile(
    ctx.stackConfigPath,
    'config:\n  geoff-cloud:nixie:\n    image: ghcr.io/zgeoff/nixie:0.74.0@sha256:456a48906e5ae0c444d84860057ad59e52a90ba485eceb64ea9437474372db6f\n',
  );

  const kubectl = buildStubKubectlToken({
    adminKubeconfig: '/runner/k3s-kubeconfig',
    server: 'https://cluster.example.test:6443',
    certificateAuthorityData: 'Y2EtZm9yLXRlc3Rz',
    token: 'fake-token-for-tests',
    nowMs: Date.parse('2026-11-15T06:00:00Z'),
  });

  const runner = buildStubRunner(kubectl.handler, buildStubNixieCheckout({}).handler);

  await ctx.check(runner.run);

  expect(runner.calls).toSatisfyAll(
    (call: StubCall) =>
      !JSON.stringify([call.argv, call.options.env ?? {}]).includes('fake-token-for-tests'),
  );
});

test('it fails, prints the doctor, still detaches and removes the kubeconfig when a check fails', async () => {
  const ctx = await setupTest();

  await writeFile(
    ctx.stackConfigPath,
    'config:\n  geoff-cloud:nixie:\n    image: ghcr.io/zgeoff/nixie:0.74.0@sha256:456a48906e5ae0c444d84860057ad59e52a90ba485eceb64ea9437474372db6f\n',
  );

  const kubectl = buildStubKubectlToken({
    adminKubeconfig: '/runner/k3s-kubeconfig',
    server: 'https://cluster.example.test:6443',
    certificateAuthorityData: 'Y2EtZm9yLXRlc3Rz',
    token: 'fake-token-for-tests',
    nowMs: Date.parse('2026-11-15T06:00:00Z'),
  });

  const checkout = buildStubNixieCheckout({
    doctor: { exitCode: 1, stdout: '{"ok":false}\n' },
  });

  const runner = buildStubRunner(kubectl.handler, checkout.handler);

  const exitCode = await ctx.check(runner.run);

  expect({
    exitCode,
    out: ctx.printOut.mock.calls,
    err: ctx.printErr.mock.calls,
    last: runner.calls.at(-1)?.argv,
    kubeconfig: existsSync(join(ctx.workDir, 'nixie-verify-kubeconfig.yaml')),
  }).toStrictEqual({
    exitCode: 1,
    out: [['::add-mask::fake-token-for-tests\n'], ['{"ok":false}\n']],
    err: [["run-nixie-doctor-check: nixie's prod doctor exited 1; its results are above\n"]],
    last: ['bun', 'run', '--silent', 'verify', 'detach', '--target', 'prod'],
    kubeconfig: false,
  });
});

test('it fails before it mints a token when the pinned release has no tag', async () => {
  const ctx = await setupTest();

  await writeFile(
    ctx.stackConfigPath,
    'config:\n  geoff-cloud:nixie:\n    image: ghcr.io/zgeoff/nixie:0.74.0@sha256:456a48906e5ae0c444d84860057ad59e52a90ba485eceb64ea9437474372db6f\n',
  );

  const kubectl = buildStubKubectlToken({
    adminKubeconfig: '/runner/k3s-kubeconfig',
    server: 'https://cluster.example.test:6443',
    certificateAuthorityData: 'Y2EtZm9yLXRlc3Rz',
    token: 'fake-token-for-tests',
    nowMs: Date.parse('2026-11-15T06:00:00Z'),
  });

  // git's answer to a clone of a branch or tag that the remote lacks
  const checkout = buildStubNixieCheckout({
    clone: {
      exitCode: 128,
      stderr:
        'warning: Could not find remote branch v0.74.0 to clone.\nfatal: Remote branch v0.74.0 not found in upstream origin\n',
    },
  });

  const runner = buildStubRunner(kubectl.handler, checkout.handler);

  const exitCode = await ctx.check(runner.run);

  expect({ exitCode, err: ctx.printErr.mock.calls, durations: kubectl.durations }).toStrictEqual({
    exitCode: 1,
    err: [
      [
        'run-nixie-doctor-check: could not check out nixie v0.74.0 (exit 128): warning: Could not find remote branch v0.74.0 to clone.\nfatal: Remote branch v0.74.0 not found in upstream origin\n',
      ],
    ],
    durations: [],
  });
});

test('it fails before the doctor runs when kubectl mints no token', async () => {
  const ctx = await setupTest();

  await writeFile(
    ctx.stackConfigPath,
    'config:\n  geoff-cloud:nixie:\n    image: ghcr.io/zgeoff/nixie:0.74.0@sha256:456a48906e5ae0c444d84860057ad59e52a90ba485eceb64ea9437474372db6f\n',
  );

  const kubectl = buildStubKubectlToken({
    adminKubeconfig: '/runner/k3s-kubeconfig',
    server: 'https://cluster.example.test:6443',
    certificateAuthorityData: 'Y2EtZm9yLXRlc3Rz',
    nowMs: Date.parse('2026-11-15T06:00:00Z'),
  });

  const runner = buildStubRunner(kubectl.handler, buildStubNixieCheckout({}).handler);

  const exitCode = await ctx.check(runner.run);

  expect({
    exitCode,
    err: ctx.printErr.mock.calls,
    verifyCalls: runner.calls.filter((call) => call.argv.includes('verify')),
  }).toStrictEqual({
    exitCode: 1,
    err: [
      [
        'run-nixie-doctor-check: kubectl minted no token for nixie-verify (exit 1): error: failed to create token: serviceaccounts "nixie-verify" not found\n',
      ],
    ],
    verifyCalls: [],
  });
});

test('it fails without running the doctor when attach fails', async () => {
  const ctx = await setupTest();

  await writeFile(
    ctx.stackConfigPath,
    'config:\n  geoff-cloud:nixie:\n    image: ghcr.io/zgeoff/nixie:0.74.0@sha256:456a48906e5ae0c444d84860057ad59e52a90ba485eceb64ea9437474372db6f\n',
  );

  const kubectl = buildStubKubectlToken({
    adminKubeconfig: '/runner/k3s-kubeconfig',
    server: 'https://cluster.example.test:6443',
    certificateAuthorityData: 'Y2EtZm9yLXRlc3Rz',
    token: 'fake-token-for-tests',
    nowMs: Date.parse('2026-11-15T06:00:00Z'),
  });

  // the verify CLI's answer in a release with no prod target
  const checkout = buildStubNixieCheckout({
    attach: {
      exitCode: 2,
      stdout:
        '{"wringer":1,"ok":false,"command":"attach","error":{"code":"usage","message":"The repo has no target named prod."}}\n',
    },
  });

  const runner = buildStubRunner(kubectl.handler, checkout.handler);

  const exitCode = await ctx.check(runner.run);

  expect({
    exitCode,
    err: ctx.printErr.mock.calls,
    doctors: checkout.kubeconfigs.length,
    kubeconfig: existsSync(join(ctx.workDir, 'nixie-verify-kubeconfig.yaml')),
  }).toStrictEqual({
    exitCode: 1,
    err: [
      [
        'run-nixie-doctor-check: bun verify attach exited 2: {"wringer":1,"ok":false,"command":"attach","error":{"code":"usage","message":"The repo has no target named prod."}}\n',
      ],
    ],
    doctors: 0,
    kubeconfig: false,
  });
});

test('it fails with no call when the stack config pins no nixie version', async () => {
  const ctx = await setupTest();

  await writeFile(
    ctx.stackConfigPath,
    'config:\n  geoff-cloud:nixie:\n    image: ghcr.io/zgeoff/nixie:latest\n',
  );

  const runner = buildStubRunner();

  const exitCode = await ctx.check(runner.run);

  expect({ exitCode, err: ctx.printErr.mock.calls, calls: runner.calls }).toStrictEqual({
    exitCode: 1,
    err: [[`run-nixie-doctor-check: ${ctx.stackConfigPath} pins no nixie image with a version\n`]],
    calls: [],
  });
});

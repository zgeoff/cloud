import { expect, mock, onTestFinished, test } from 'bun:test';
import { existsSync } from 'node:fs';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { findJSONField } from './find-json-field.ts';
import { runNixieDoctorCheck } from './run-nixie-doctor-check.ts';
import type { Runner } from './run-process.ts';
import { buildStubKubectlToken } from './test-utils/build-stub-kubectl-token.ts';
import { buildStubNixieContainer } from './test-utils/build-stub-nixie-container.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'run-nixie-doctor-check-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const stackConfigPath = join(directory, 'Pulumi.prod.yaml');
  const workDir = join(directory, 'runner-temp', 'nixie-doctor');
  const adminKubeconfig = join(directory, 'runner-temp', 'k3s-kubeconfig');
  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  await writeFile(
    stackConfigPath,
    'config:\n  geoff-cloud:nixie:\n    image: ghcr.io/zgeoff/nixie:0.74.0@sha256:456a48906e5ae0c444d84860057ad59e52a90ba485eceb64ea9437474372db6f\n',
  );

  return {
    stackConfigPath,
    workDir,
    adminKubeconfig,
    printOut,
    printErr,
    check: (run: Runner) =>
      runNixieDoctorCheck({
        run,
        stackConfigPath,
        adminKubeconfig,
        workDir,
        imageContext: 'images/nixie-doctor',
        kubectlPath: '/usr/local/bin/kubectl',
        user: '1001:118',
        path: '/usr/bin:/bin',
        home: '/runner/home',
        printOut,
        printErr,
      }),
  };
}

test("it runs the pinned release's prod doctor in a container, as nixie-verify with a 10-minute token", async () => {
  const ctx = await setupTest();

  const kubectl = buildStubKubectlToken({
    adminKubeconfig: ctx.adminKubeconfig,
    server: 'https://cluster.example.test:6443',
    certificateAuthorityData: 'Y2EtZm9yLXRlc3Rz',
    token: 'fake-token-for-tests',
    nowMs: Date.parse('2026-11-15T06:00:00Z'),
  });

  const docker = buildStubNixieContainer({ doctor: { stdout: '{"ok":true}\n' } });
  const runner = buildStubRunner(kubectl.handler, docker.handler);

  const exitCode = await ctx.check(runner.run);

  const nixie = join(ctx.workDir, 'nixie');
  const kube = join(ctx.workDir, 'kube');
  const env = { PATH: '/usr/bin:/bin', HOME: '/runner/home' };

  expect({ exitCode, out: ctx.printOut.mock.calls, err: ctx.printErr.mock.calls }).toStrictEqual({
    exitCode: 0,
    out: [
      ['::add-mask::fake-token-for-tests\n'],
      ['{"ok":true}\n'],
      ['nixie prod doctor passed\n'],
    ],
    err: [],
  });

  expect(runner.calls.map((call) => ({ argv: call.argv, env: call.options.env }))).toStrictEqual([
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
      env,
    },
    { argv: ['git', '-C', nixie, 'switch', '--quiet', '--create', 'main'], env },
    {
      argv: [
        'docker',
        'build',
        '--quiet',
        '--tag',
        'nixie-doctor-check:local',
        'images/nixie-doctor',
      ],
      env,
    },
    {
      argv: [
        'docker',
        'run',
        '--detach',
        '--name',
        'nixie-doctor-check',
        '--network',
        'host',
        '--read-only',
        '--tmpfs',
        '/tmp',
        '--cap-drop',
        'ALL',
        '--security-opt',
        'no-new-privileges',
        '--user',
        '1001:118',
        '--env',
        'HOME=/tmp',
        '--env',
        'NIXIE_PROD_KUBECONFIG=/kube/config',
        '--env',
        'NIXIE_PROD_VERSION=0.74.0',
        '--volume',
        `${nixie}:/nixie`,
        '--volume',
        `${kube}:/kube:ro`,
        '--volume',
        '/usr/local/bin/kubectl:/usr/local/bin/kubectl:ro',
        '--workdir',
        '/nixie',
        'nixie-doctor-check:local',
        'sleep',
        'infinity',
      ],
      env,
    },
    { argv: ['docker', 'exec', 'nixie-doctor-check', 'bun', '--version'], env },
    {
      argv: [
        'docker',
        'exec',
        'nixie-doctor-check',
        'bun',
        'install',
        '--frozen-lockfile',
        '--ignore-scripts',
      ],
      env,
    },
    {
      argv: [
        'kubectl',
        '--kubeconfig',
        ctx.adminKubeconfig,
        'config',
        'view',
        '--minify',
        '--flatten',
        '--output',
        String.raw`jsonpath={.clusters[0].cluster.server}{"\n"}{.clusters[0].cluster.certificate-authority-data}`,
      ],
      env: undefined,
    },
    {
      argv: [
        'kubectl',
        '--kubeconfig',
        ctx.adminKubeconfig,
        '--namespace',
        'nixie',
        'create',
        'token',
        'nixie-verify',
        '--duration=10m',
        '--output',
        'json',
      ],
      env: undefined,
    },
    {
      argv: [
        'docker',
        'exec',
        'nixie-doctor-check',
        'bun',
        'run',
        '--silent',
        'verify',
        'attach',
        '--target',
        'prod',
      ],
      env,
    },
    {
      argv: [
        'docker',
        'exec',
        'nixie-doctor-check',
        'bun',
        'run',
        '--silent',
        'verify',
        'doctor',
        '--json',
        '--target',
        'prod',
      ],
      env,
    },
    {
      argv: [
        'docker',
        'exec',
        'nixie-doctor-check',
        'bun',
        'run',
        '--silent',
        'verify',
        'detach',
        '--target',
        'prod',
      ],
      env,
    },
    { argv: ['docker', 'rm', '--force', 'nixie-doctor-check'], env },
  ]);
});

test('it gives the container no mount that holds the admin kubeconfig, and no environment but its own three', async () => {
  const ctx = await setupTest();

  const kubectl = buildStubKubectlToken({
    adminKubeconfig: ctx.adminKubeconfig,
    server: 'https://cluster.example.test:6443',
    certificateAuthorityData: 'Y2EtZm9yLXRlc3Rz',
    token: 'fake-token-for-tests',
    nowMs: Date.parse('2026-11-15T06:00:00Z'),
  });

  const runner = buildStubRunner(kubectl.handler, buildStubNixieContainer({}).handler);

  await ctx.check(runner.run);

  const dockerCalls = runner.calls.filter((call) => call.argv[0] === 'docker');
  const started = dockerCalls.find((call) => call.argv[1] === 'run')?.argv ?? [];
  const valuesOf = (flag: string) => started.filter((_, index) => started[index - 1] === flag);
  const mountSources = valuesOf('--volume').map((volume) => volume.split(':')[0] ?? '');

  expect({
    mountSources,
    mountsHoldingTheAdminKubeconfig: mountSources.filter((source) =>
      ctx.adminKubeconfig.startsWith(source),
    ),
    environment: valuesOf('--env'),
    otherEnvironmentFlags: started.filter(
      (arg) => arg === '-e' || arg === '-v' || arg.startsWith('--env-file') || arg === '--mount',
    ),

    // `docker exec --env` or `-e` would add a variable after the start
    execEnvironment: dockerCalls
      .filter((call) => call.argv[1] === 'exec')
      .flatMap((call) => call.argv.filter((arg) => arg.startsWith('--env') || arg === '-e')),
  }).toStrictEqual({
    mountSources: [join(ctx.workDir, 'nixie'), join(ctx.workDir, 'kube'), '/usr/local/bin/kubectl'],
    mountsHoldingTheAdminKubeconfig: [],
    environment: ['HOME=/tmp', 'NIXIE_PROD_KUBECONFIG=/kube/config', 'NIXIE_PROD_VERSION=0.74.0'],
    otherEnvironmentFlags: [],
    execEnvironment: [],
  });
});

test('it keeps the token out of every argv and every environment, and gives it to the container only as a file', async () => {
  const ctx = await setupTest();

  const kubectl = buildStubKubectlToken({
    adminKubeconfig: ctx.adminKubeconfig,
    server: 'https://cluster.example.test:6443',
    certificateAuthorityData: 'Y2EtZm9yLXRlc3Rz',
    token: 'fake-token-for-tests',
    nowMs: Date.parse('2026-11-15T06:00:00Z'),
  });

  const docker = buildStubNixieContainer({});
  const runner = buildStubRunner(kubectl.handler, docker.handler);

  await ctx.check(runner.run);

  expect({
    leaks: runner.calls.filter((call) =>
      JSON.stringify([call.argv, call.options.env ?? {}]).includes('fake-token-for-tests'),
    ),
    kubeconfigs: docker.kubeconfigs.map((read) => ({
      mode: read.mode,
      users: findJSONField(Bun.YAML.parse(read.text), 'users'),
    })),
    left: existsSync(join(ctx.workDir, 'kube')),
  }).toStrictEqual({
    leaks: [],
    kubeconfigs: [
      { mode: 0o600, users: [{ name: 'nixie-verify', user: { token: 'fake-token-for-tests' } }] },
    ],
    left: false,
  });
});

test('it fails, prints the doctor, still detaches and removes the container when a check fails', async () => {
  const ctx = await setupTest();

  const kubectl = buildStubKubectlToken({
    adminKubeconfig: ctx.adminKubeconfig,
    server: 'https://cluster.example.test:6443',
    certificateAuthorityData: 'Y2EtZm9yLXRlc3Rz',
    token: 'fake-token-for-tests',
    nowMs: Date.parse('2026-11-15T06:00:00Z'),
  });

  const docker = buildStubNixieContainer({ doctor: { exitCode: 1, stdout: '{"ok":false}\n' } });
  const runner = buildStubRunner(kubectl.handler, docker.handler);

  const exitCode = await ctx.check(runner.run);

  expect({
    exitCode,
    out: ctx.printOut.mock.calls,
    err: ctx.printErr.mock.calls,
    lastTwo: runner.calls.slice(-2).map((call) => call.argv.slice(-3)),
    left: existsSync(join(ctx.workDir, 'kube')),
  }).toStrictEqual({
    exitCode: 1,
    out: [['::add-mask::fake-token-for-tests\n'], ['{"ok":false}\n']],
    err: [["run-nixie-doctor-check: nixie's prod doctor exited 1; its results are above\n"]],
    lastTwo: [
      ['detach', '--target', 'prod'],
      ['rm', '--force', 'nixie-doctor-check'],
    ],
    left: false,
  });
});

test('it fails when the doctor passes but detach fails', async () => {
  const ctx = await setupTest();

  const kubectl = buildStubKubectlToken({
    adminKubeconfig: ctx.adminKubeconfig,
    server: 'https://cluster.example.test:6443',
    certificateAuthorityData: 'Y2EtZm9yLXRlc3Rz',
    token: 'fake-token-for-tests',
    nowMs: Date.parse('2026-11-15T06:00:00Z'),
  });

  const docker = buildStubNixieContainer({
    doctor: { stdout: '{"ok":true}\n' },
    detach: { exitCode: 1, stdout: '{"ok":false,"command":"detach"}\n' },
  });

  const runner = buildStubRunner(kubectl.handler, docker.handler);

  const exitCode = await ctx.check(runner.run);

  expect({ exitCode, err: ctx.printErr.mock.calls }).toStrictEqual({
    exitCode: 1,
    err: [
      ['run-nixie-doctor-check: bun verify detach exited 1: {"ok":false,"command":"detach"}\n'],
    ],
  });
});

test('it fails when the doctor outlives its timeout, even when it then exits 0', async () => {
  const ctx = await setupTest();

  const kubectl = buildStubKubectlToken({
    adminKubeconfig: ctx.adminKubeconfig,
    server: 'https://cluster.example.test:6443',
    certificateAuthorityData: 'Y2EtZm9yLXRlc3Rz',
    token: 'fake-token-for-tests',
    nowMs: Date.parse('2026-11-15T06:00:00Z'),
  });

  const docker = buildStubNixieContainer({ doctor: { timedOut: true, stdout: '{"ok":true}\n' } });
  const runner = buildStubRunner(kubectl.handler, docker.handler);

  const exitCode = await ctx.check(runner.run);

  expect({ exitCode, err: ctx.printErr.mock.calls }).toStrictEqual({
    exitCode: 1,
    err: [["run-nixie-doctor-check: nixie's prod doctor exited 124; its results are above\n"]],
  });
});

test('it gives each call to git and docker a SIGKILL after its timeout', async () => {
  const ctx = await setupTest();

  const kubectl = buildStubKubectlToken({
    adminKubeconfig: ctx.adminKubeconfig,
    server: 'https://cluster.example.test:6443',
    certificateAuthorityData: 'Y2EtZm9yLXRlc3Rz',
    token: 'fake-token-for-tests',
    nowMs: Date.parse('2026-11-15T06:00:00Z'),
  });

  const runner = buildStubRunner(kubectl.handler, buildStubNixieContainer({}).handler);
  const stops: string[] = [];

  await ctx.check((argv, options) => {
    stops.push(`${argv[0] ?? ''} ${options?.forceStop === undefined ? 'none' : 'SIGKILL'}`);

    return runner.run(argv, options);
  });

  expect(stops).toStrictEqual([
    'git SIGKILL',
    'git SIGKILL',
    'docker SIGKILL',
    'docker SIGKILL',
    'docker SIGKILL',
    'docker SIGKILL',
    'kubectl SIGKILL',
    'kubectl SIGKILL',
    'docker SIGKILL',
    'docker SIGKILL',
    'docker SIGKILL',
    'docker SIGKILL',
  ]);
});

test('it fails when the container outlives its removal, even after the doctor passed', async () => {
  const ctx = await setupTest();

  const kubectl = buildStubKubectlToken({
    adminKubeconfig: ctx.adminKubeconfig,
    server: 'https://cluster.example.test:6443',
    certificateAuthorityData: 'Y2EtZm9yLXRlc3Rz',
    token: 'fake-token-for-tests',
    nowMs: Date.parse('2026-11-15T06:00:00Z'),
  });

  const docker = buildStubNixieContainer({
    remove: {
      exitCode: 1,
      stderr: 'Error response from daemon: cannot remove container "nixie-doctor-check"\n',
    },
  });

  const runner = buildStubRunner(kubectl.handler, docker.handler);

  const exitCode = await ctx.check(runner.run);

  expect({ exitCode, err: ctx.printErr.mock.calls }).toStrictEqual({
    exitCode: 1,
    err: [
      [
        'run-nixie-doctor-check: could not remove the doctor\'s container (exit 1): Error response from daemon: cannot remove container "nixie-doctor-check"\n',
      ],
    ],
  });
});

test('it removes the container and the kubeconfig folder when a step throws, then throws on', async () => {
  const ctx = await setupTest();

  const kubectl = buildStubKubectlToken({
    adminKubeconfig: ctx.adminKubeconfig,
    server: 'https://cluster.example.test:6443',
    certificateAuthorityData: 'Y2EtZm9yLXRlc3Rz',
    token: 'fake-token-for-tests',
    nowMs: Date.parse('2026-11-15T06:00:00Z'),
  });

  const kube = join(ctx.workDir, 'kube');

  // the folder goes before the mint, so the kubeconfig's write throws ENOENT
  const runner = buildStubRunner(async (call) => {
    if (call.argv.includes('create')) {
      await rm(kube, { recursive: true });
    }

    return kubectl.handler(call);
  }, buildStubNixieContainer({}).handler);

  const thrown = await ctx.check(runner.run).catch((error: unknown) => error);

  expect({
    thrown: thrown instanceof Error && 'code' in thrown ? thrown.code : thrown,
    last: runner.calls.at(-1)?.argv,
    left: existsSync(kube),
  }).toStrictEqual({
    thrown: 'ENOENT',
    last: ['docker', 'rm', '--force', 'nixie-doctor-check'],
    left: false,
  });
});

test("it removes the container and mints no token when the image's Bun differs from nixie's", async () => {
  const ctx = await setupTest();

  const kubectl = buildStubKubectlToken({
    adminKubeconfig: ctx.adminKubeconfig,
    server: 'https://cluster.example.test:6443',
    certificateAuthorityData: 'Y2EtZm9yLXRlc3Rz',
    token: 'fake-token-for-tests',
    nowMs: Date.parse('2026-11-15T06:00:00Z'),
  });

  const docker = buildStubNixieContainer({ bunVersion: '1.5.0', imageBunVersion: '1.4.4' });
  const runner = buildStubRunner(kubectl.handler, docker.handler);

  const exitCode = await ctx.check(runner.run);

  expect({
    exitCode,
    err: ctx.printErr.mock.calls,
    durations: kubectl.durations,
    last: runner.calls.at(-1)?.argv,
  }).toStrictEqual({
    exitCode: 1,
    err: [
      [
        "run-nixie-doctor-check: nixie v0.74.0 wants Bun 1.5.0, and the doctor's image has Bun 1.4.4; move images/nixie-doctor/Dockerfile to it\n",
      ],
    ],
    durations: [],
    last: ['docker', 'rm', '--force', 'nixie-doctor-check'],
  });
});

test('it never reads the admin kubeconfig through a .bun-version that links to it', async () => {
  const ctx = await setupTest();

  await mkdir(dirname(ctx.adminKubeconfig), { recursive: true });
  await writeFile(ctx.adminKubeconfig, 'users:\n- user:\n    token: fake-admin-token-for-tests\n');

  const kubectl = buildStubKubectlToken({
    adminKubeconfig: ctx.adminKubeconfig,
    server: 'https://cluster.example.test:6443',
    certificateAuthorityData: 'Y2EtZm9yLXRlc3Rz',
    token: 'fake-token-for-tests',
    nowMs: Date.parse('2026-11-15T06:00:00Z'),
  });

  const docker = buildStubNixieContainer({ bunVersionLinksTo: ctx.adminKubeconfig });
  const runner = buildStubRunner(kubectl.handler, docker.handler);

  const exitCode = await ctx.check(runner.run);

  const printed = JSON.stringify([ctx.printOut.mock.calls, ctx.printErr.mock.calls]);

  expect({
    exitCode,
    leaked: printed.includes('fake-admin-token-for-tests'),
    durations: kubectl.durations,
    last: runner.calls.at(-1)?.argv,
  }).toStrictEqual({
    exitCode: 1,
    leaked: false,
    durations: [],
    last: ['docker', 'rm', '--force', 'nixie-doctor-check'],
  });
});

test('it fails before it mints a token when the pinned release has no tag', async () => {
  const ctx = await setupTest();

  const kubectl = buildStubKubectlToken({
    adminKubeconfig: ctx.adminKubeconfig,
    server: 'https://cluster.example.test:6443',
    certificateAuthorityData: 'Y2EtZm9yLXRlc3Rz',
    token: 'fake-token-for-tests',
    nowMs: Date.parse('2026-11-15T06:00:00Z'),
  });

  // git's answer to a clone of a branch or tag that the remote lacks
  const docker = buildStubNixieContainer({
    clone: {
      exitCode: 128,
      stderr:
        'warning: Could not find remote branch v0.74.0 to clone.\nfatal: Remote branch v0.74.0 not found in upstream origin\n',
    },
  });

  const runner = buildStubRunner(kubectl.handler, docker.handler);

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

test('it fails before the doctor runs, and removes the container, when kubectl mints no token', async () => {
  const ctx = await setupTest();

  const kubectl = buildStubKubectlToken({
    adminKubeconfig: ctx.adminKubeconfig,
    server: 'https://cluster.example.test:6443',
    certificateAuthorityData: 'Y2EtZm9yLXRlc3Rz',
    nowMs: Date.parse('2026-11-15T06:00:00Z'),
  });

  const runner = buildStubRunner(kubectl.handler, buildStubNixieContainer({}).handler);

  const exitCode = await ctx.check(runner.run);

  expect({
    exitCode,
    err: ctx.printErr.mock.calls,
    verifyCalls: runner.calls.filter((call) => call.argv.includes('verify')),
    last: runner.calls.at(-1)?.argv,
  }).toStrictEqual({
    exitCode: 1,
    err: [
      [
        'run-nixie-doctor-check: kubectl minted no token for nixie-verify (exit 1): error: failed to create token: serviceaccounts "nixie-verify" not found\n',
      ],
    ],
    verifyCalls: [],
    last: ['docker', 'rm', '--force', 'nixie-doctor-check'],
  });
});

test('it fails without running the doctor when attach fails', async () => {
  const ctx = await setupTest();

  const kubectl = buildStubKubectlToken({
    adminKubeconfig: ctx.adminKubeconfig,
    server: 'https://cluster.example.test:6443',
    certificateAuthorityData: 'Y2EtZm9yLXRlc3Rz',
    token: 'fake-token-for-tests',
    nowMs: Date.parse('2026-11-15T06:00:00Z'),
  });

  // the verify CLI's answer in a release with no prod target
  const docker = buildStubNixieContainer({
    attach: {
      exitCode: 2,
      stdout:
        '{"wringer":1,"ok":false,"command":"attach","error":{"code":"usage","message":"The repo has no target named prod."}}\n',
    },
  });

  const runner = buildStubRunner(kubectl.handler, docker.handler);

  const exitCode = await ctx.check(runner.run);

  expect({
    exitCode,
    err: ctx.printErr.mock.calls,
    doctors: docker.kubeconfigs.length,
    left: existsSync(join(ctx.workDir, 'kube')),
  }).toStrictEqual({
    exitCode: 1,
    err: [
      [
        'run-nixie-doctor-check: bun verify attach exited 2: {"wringer":1,"ok":false,"command":"attach","error":{"code":"usage","message":"The repo has no target named prod."}}\n',
      ],
    ],
    doctors: 0,
    left: false,
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

import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createNixieVerifyKubeconfig } from './nixie-verify/create-nixie-verify-kubeconfig.ts';
import { findNixieVersion } from './nixie-verify/find-nixie-version.ts';
import type { RunOptions, RunResult, Runner } from './run-process.ts';
import { runProcess } from './run-process.ts';

export interface RunNixieDoctorCheckOptions {
  readonly run: Runner;

  // the applied commit's stack config, whose nixie pin names the release to check
  readonly stackConfigPath: string;

  // the deploy job's admin kubeconfig, which only mints the doctor's token on the runner
  readonly adminKubeconfig: string;

  // an empty folder for nixie's checkout and the doctor's kubeconfig
  readonly workDir: string;

  // the folder that holds the doctor container's Dockerfile
  readonly imageContext: string;

  // the runner's kubectl, which the container gets read-only
  readonly kubectlPath: string;

  // the uid:gid the container runs as, which owns the checkout and the doctor's kubeconfig
  readonly user: string;

  // what git and docker on the runner inherit: PATH and HOME, and nothing of the job's credentials
  readonly path: string;
  readonly home: string;
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

const nixieRepoURL = 'https://github.com/zgeoff/nixie.git';
const image = 'nixie-doctor-check:local';
const container = 'nixie-doctor-check';

// how long a call that its timeout's SIGTERM did not stop gets before SIGKILL; the step's
// timeout covers every call's timeout and this
const forceStopAfterMs = 10_000;

// Runs nixie's prod doctor, from the pinned release, as the read-only nixie-verify account. nixie's
// code and dependencies run in a container that holds only the checkout, that account's
// kubeconfig and kubectl, so they never reach the admin kubeconfig or another file of the job.
export async function runNixieDoctorCheck(
  options: Readonly<RunNixieDoctorCheckOptions>,
): Promise<number> {
  if (options.adminKubeconfig === '') {
    options.printErr('run-nixie-doctor-check: KUBECONFIG names no admin kubeconfig\n');

    return 1;
  }

  if (options.kubectlPath === '') {
    options.printErr('run-nixie-doctor-check: no kubectl on PATH for the container\n');

    return 1;
  }

  const stackConfigText = await readFile(options.stackConfigPath, 'utf8');

  const version = findNixieVersion(stackConfigText);

  if (version === null) {
    options.printErr(
      `run-nixie-doctor-check: ${options.stackConfigPath} pins no nixie image with a version\n`,
    );

    return 1;
  }

  const checkout = join(options.workDir, 'nixie');
  const kubeconfigDirectory = join(options.workDir, 'kube');
  const env = { PATH: options.path, HOME: options.home };

  const prepared = await runSteps(options, [
    {
      what: `check out nixie v${version}`,
      argv: [
        'git',
        '-c',
        'advice.detachedHead=false',
        'clone',
        '--quiet',
        '--depth',
        '1',
        '--branch',
        `v${version}`,
        nixieRepoURL,
        checkout,
      ],
      options: { env, timeoutMs: 120_000 },
    },
    {
      // wringer fingerprints a run's change against the branch main, which a clone of a tag lacks
      what: 'create the branch main',
      argv: ['git', '-C', checkout, 'switch', '--quiet', '--create', 'main'],
      options: { env, timeoutMs: 30_000 },
    },
    {
      what: "build the doctor's container image",
      argv: ['docker', 'build', '--quiet', '--tag', image, options.imageContext],
      options: { env, timeoutMs: 300_000 },
    },
  ]);

  if (!prepared) {
    return 1;
  }

  await mkdir(kubeconfigDirectory, { mode: 0o700 });

  const paths = { checkout, kubeconfigDirectory, version };

  // the container and the kubeconfig go even when a step throws, and the throw then goes on
  const outcome = await startAndRunContainer(options, paths).then(
    (exitCode) => ({ exitCode }),
    (error: unknown) => ({ error }),
  );

  const removed = await runBounded(options.run, ['docker', 'rm', '--force', container], {
    env,
    timeoutMs: 30_000,
  });

  await rm(kubeconfigDirectory, { recursive: true, force: true });

  if ('error' in outcome) {
    throw outcome.error;
  }

  if (removed.exitCode !== 0) {
    options.printErr(
      `run-nixie-doctor-check: could not remove the doctor's container (exit ${String(removed.exitCode)}): ${removed.stderr.toString().trim()}\n`,
    );

    return 1;
  }

  return outcome.exitCode;
}

interface BoundedRunOptions extends Omit<RunOptions, 'forceStop'> {
  readonly timeoutMs: number;
}

interface Step {
  readonly what: string;
  readonly argv: readonly string[];
  readonly options: BoundedRunOptions;
}

async function runSteps(
  options: Readonly<RunNixieDoctorCheckOptions>,
  steps: readonly Step[],
): Promise<boolean> {
  for (const step of steps) {
    const ran = await runBounded(options.run, step.argv, step.options);

    if (ran.exitCode !== 0) {
      options.printErr(
        `run-nixie-doctor-check: could not ${step.what} (exit ${String(ran.exitCode)}): ${ran.stderr.toString().trim()}\n`,
      );

      return false;
    }
  }

  return true;
}

// A call that outlives its timeout fails, even when it exits 0 after the SIGTERM, and one that
// ignores the SIGTERM gets SIGKILL.
async function runBounded(
  run: Runner,
  argv: readonly string[],
  options: Readonly<BoundedRunOptions>,
): Promise<RunResult> {
  const forceStop = AbortSignal.timeout(options.timeoutMs + forceStopAfterMs);

  const ran = await run(argv, { ...options, forceStop });

  return ran.timedOut && ran.exitCode === 0 ? { ...ran, exitCode: 124 } : ran;
}

interface DoctorPaths {
  readonly checkout: string;
  readonly kubeconfigDirectory: string;
  readonly version: string;
}

async function startAndRunContainer(
  options: Readonly<RunNixieDoctorCheckOptions>,
  paths: Readonly<DoctorPaths>,
): Promise<number> {
  const started = await runSteps(options, [
    {
      what: "start the doctor's container",
      argv: buildContainerArgv(options, paths),
      options: { env: { PATH: options.path, HOME: options.home }, timeoutMs: 60_000 },
    },
  ]);

  return started ? runInContainer(options, paths) : 1;
}

// The container sees the checkout, the folder that will hold the doctor's kubeconfig, read-only,
// and the runner's kubectl, read-only; its environment is the three variables below. It shares
// the runner's network, which reaches the k3s API over the tailnet, and keeps no capability.
function buildContainerArgv(
  options: Readonly<RunNixieDoctorCheckOptions>,
  paths: Readonly<DoctorPaths>,
): readonly string[] {
  return [
    'docker',
    'run',
    '--detach',
    '--name',
    container,
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
    options.user,
    '--env',
    'HOME=/tmp',
    '--env',
    'NIXIE_PROD_KUBECONFIG=/kube/config',
    '--env',
    `NIXIE_PROD_VERSION=${paths.version}`,
    '--volume',
    `${paths.checkout}:/nixie`,
    '--volume',
    `${paths.kubeconfigDirectory}:/kube:ro`,
    '--volume',
    `${options.kubectlPath}:/usr/local/bin/kubectl:ro`,
    '--workdir',
    '/nixie',
    image,
    'sleep',
    'infinity',
  ];
}

async function runInContainer(
  options: Readonly<RunNixieDoctorCheckOptions>,
  paths: Readonly<DoctorPaths>,
): Promise<number> {
  const env = { PATH: options.path, HOME: options.home };

  const exec = (args: readonly string[], timeoutMs: number) =>
    runBounded(options.run, ['docker', 'exec', container, ...args], { env, timeoutMs });

  const bunVersion = await exec(['bun', '--version'], 30_000);
  const wanted = await readFile(join(paths.checkout, '.bun-version'), 'utf8').catch(() => '');

  if (bunVersion.stdout.toString().trim() !== wanted.trim()) {
    options.printErr(
      `run-nixie-doctor-check: nixie v${paths.version} wants Bun ${wanted.trim()}, and the doctor's image has Bun ${bunVersion.stdout.toString().trim()}; move images/nixie-doctor/Dockerfile to it\n`,
    );

    return 1;
  }

  const installed = await runSteps(options, [
    {
      // the doctor runs none of the install scripts, which build nixie's web client and git hooks
      what: "install nixie's dependencies",
      argv: [
        'docker',
        'exec',
        container,
        'bun',
        'install',
        '--frozen-lockfile',
        '--ignore-scripts',
      ],
      options: { env, timeoutMs: 300_000 },
    },
  ]);

  if (!installed) {
    return 1;
  }

  // kubectl's calls get the same SIGKILL as every other call
  const boundedRun: Runner = (argv, runOptions) =>
    runBounded(options.run, argv, { ...runOptions, timeoutMs: runOptions?.timeoutMs ?? 30_000 });

  const minted = await createNixieVerifyKubeconfig(boundedRun, {
    adminKubeconfig: options.adminKubeconfig,
    duration: '10m',
  });

  if (!minted.ok) {
    options.printErr(`run-nixie-doctor-check: ${minted.error}\n`);

    return 1;
  }

  options.printOut(`::add-mask::${minted.token}\n`);

  await writeFile(join(paths.kubeconfigDirectory, 'config'), minted.text, { mode: 0o600 });

  return runDoctor(options, (args, timeoutMs) =>
    exec(['bun', 'run', '--silent', 'verify', ...args, '--target', 'prod'], timeoutMs),
  );
}

type Verify = (args: readonly string[], timeoutMs: number) => Promise<RunResult>;

// The verify CLI prints one JSON line per check and a last line with every result. Only check
// names, statuses and messages leave nixie's checks, never a log line or a record.
async function runDoctor(
  options: Readonly<RunNixieDoctorCheckOptions>,
  verify: Verify,
): Promise<number> {
  const attached = await verify(['attach'], 60_000);

  if (attached.exitCode !== 0) {
    options.printErr(
      `run-nixie-doctor-check: bun verify attach exited ${String(attached.exitCode)}: ${attached.stdout.toString().trim()}\n`,
    );

    return 1;
  }

  const checked = await verify(['doctor', '--json'], 180_000);

  options.printOut(checked.stdout.toString());

  const detached = await verify(['detach'], 60_000);

  if (checked.exitCode !== 0) {
    options.printErr(
      `run-nixie-doctor-check: nixie's prod doctor exited ${String(checked.exitCode)}; its results are above\n${checked.stderr.toString()}`,
    );
  }

  if (detached.exitCode !== 0) {
    options.printErr(
      `run-nixie-doctor-check: bun verify detach exited ${String(detached.exitCode)}: ${detached.stdout.toString().trim()}\n`,
    );
  }

  if (checked.exitCode !== 0 || detached.exitCode !== 0) {
    return 1;
  }

  options.printOut('nixie prod doctor passed\n');

  return 0;
}

if (import.meta.main) {
  process.exitCode = await runNixieDoctorCheck({
    run: runProcess,
    stackConfigPath: 'infra/Pulumi.prod.yaml',
    adminKubeconfig: process.env['KUBECONFIG'] ?? '',
    workDir: join(process.env['RUNNER_TEMP'] ?? '', 'nixie-doctor'),
    imageContext: 'images/nixie-doctor',
    kubectlPath: Bun.which('kubectl') ?? '',
    user: `${String(process.getuid?.() ?? 0)}:${String(process.getgid?.() ?? 0)}`,
    path: process.env['PATH'] ?? '',
    home: process.env['HOME'] ?? '',
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}

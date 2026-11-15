import { readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createNixieVerifyKubeconfig } from './nixie-verify/create-nixie-verify-kubeconfig.ts';
import { findNixieVersion } from './nixie-verify/find-nixie-version.ts';
import type { RunOptions, RunResult, Runner } from './run-process.ts';
import { runProcess } from './run-process.ts';

export interface RunNixieDoctorCheckOptions {
  readonly run: Runner;

  // the applied commit's stack config, whose nixie pin names the release to check
  readonly stackConfigPath: string;

  // the deploy job's admin kubeconfig, which only mints the doctor's token
  readonly adminKubeconfig: string;

  // an empty folder for nixie's checkout and the doctor's kubeconfig
  readonly workDir: string;

  // what nixie's own processes inherit: PATH and HOME, and nothing of the job's credentials
  readonly path: string;
  readonly home: string;
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

const nixieRepoURL = 'https://github.com/zgeoff/nixie.git';

// how long a call that its timeout's SIGTERM did not stop gets before SIGKILL; the step's
// timeout covers every call's timeout and this
const forceStopAfterMs = 10_000;

// Runs nixie's own prod doctor, from the release the commit pins, as the nixie-verify account,
// which may only read nixie's pod, its log, its StatefulSet and its readiness.
export async function runNixieDoctorCheck(
  options: Readonly<RunNixieDoctorCheckOptions>,
): Promise<number> {
  if (options.adminKubeconfig === '') {
    options.printErr('run-nixie-doctor-check: KUBECONFIG names no admin kubeconfig\n');

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
      // the doctor runs none of the install scripts, which build nixie's web client and git hooks
      what: "install nixie's dependencies",
      argv: ['bun', 'install', '--frozen-lockfile', '--ignore-scripts'],
      options: { env, cwd: checkout, timeoutMs: 300_000 },
    },
  ]);

  if (!prepared) {
    return 1;
  }

  const minted = await createNixieVerifyKubeconfig(options.run, {
    adminKubeconfig: options.adminKubeconfig,
    duration: '10m',
  });

  if (!minted.ok) {
    options.printErr(`run-nixie-doctor-check: ${minted.error}\n`);

    return 1;
  }

  options.printOut(`::add-mask::${minted.token}\n`);

  const kubeconfig = join(options.workDir, 'nixie-verify-kubeconfig.yaml');

  await writeFile(kubeconfig, minted.text, { mode: 0o600 });

  const exitCode = await runDoctor(options, {
    cwd: checkout,
    env: { ...env, NIXIE_PROD_KUBECONFIG: kubeconfig, NIXIE_PROD_VERSION: version },
  });

  await rm(kubeconfig, { force: true });

  return exitCode;
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

interface DoctorRun {
  readonly cwd: string;
  readonly env: Readonly<Record<string, string>>;
}

// The verify CLI prints one JSON line per check and a last line with every result. Only check
// names, statuses and messages leave nixie's checks, never a log line or a record.
async function runDoctor(
  options: Readonly<RunNixieDoctorCheckOptions>,
  doctor: DoctorRun,
): Promise<number> {
  const verify = (args: readonly string[], timeoutMs: number) =>
    runBounded(options.run, ['bun', 'run', '--silent', 'verify', ...args, '--target', 'prod'], {
      cwd: doctor.cwd,
      env: doctor.env,
      timeoutMs,
    });

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

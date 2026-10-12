// Wipes nixie's data on geoffcloud and prints a fresh enrolment code. Only --confirm changes
// anything: --dry-run lists the files and the steps, and no flag refuses before reaching the host.
interface RemoteResult {
  readonly exitCode: number;
  readonly stdout: string;
  readonly stderr: string;
}

interface ResetNixieOptions {
  // the command-line arguments after the script name
  readonly args: readonly string[];

  // runs one command line as root on geoffcloud; the line lands in the host's journal, so it never
  // carries a secret
  readonly runRemote: (command: string) => Promise<RemoteResult>;
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

const usage = 'usage: bun run nixie:reset --dry-run | --confirm\n';

// Resets nixie's data and returns the exit code: 0 on success or a dry run, 1 on a refusal or a
// failed step, 2 on bad arguments
export async function resetNixie(options: Readonly<ResetNixieOptions>): Promise<number> {
  const mode = parseMode(options.args);

  if (mode === 'invalid') {
    return printFailure(options, usage, 2);
  }

  if (mode === 'refuse') {
    return printFailure(
      options,
      `reset-nixie: refusing to delete nixie's data without --confirm; --dry-run lists what it deletes\n${usage}`,
      1,
    );
  }

  const plan = await loadPlan(options);

  if (plan === undefined) {
    return 1;
  }

  options.printOut(renderPlan(plan));

  return mode === 'dry-run' ? printDryRunEnd(options) : runSteps(options, plan.steps, 0);
}

function parseMode(args: readonly string[]): 'refuse' | 'dry-run' | 'confirm' | 'invalid' {
  if (args.length === 0) {
    return 'refuse';
  }

  if (args.length === 1 && args[0] === '--dry-run') {
    return 'dry-run';
  }

  if (args.length === 1 && args[0] === '--confirm') {
    return 'confirm';
  }

  return 'invalid';
}

function printFailure(options: Readonly<ResetNixieOptions>, text: string, exitCode: number) {
  options.printErr(text);

  return exitCode;
}

interface Plan {
  readonly dataDir: string;

  // one `<name> <size> bytes` line per data file present on the volume
  readonly present: readonly string[];
  readonly steps: readonly Step[];
}

// Reads only: the data volume's path and the data files on it
async function loadPlan(options: Readonly<ResetNixieOptions>): Promise<Plan | undefined> {
  const volume = await readVolumeName(options);

  const dataDir = volume === undefined ? undefined : await readDataDir(options, volume);

  if (dataDir === undefined) {
    return undefined;
  }

  const listing = await options.runRemote(buildListCommand(dataDir));

  if (listing.exitCode !== 0) {
    options.printErr(`reset-nixie: cannot list the data volume: ${listing.stderr.trim()}\n`);

    return undefined;
  }

  const present = listing.stdout.split('\n').filter((line) => line !== '');

  return { dataDir, present, steps: planSteps(dataDir) };
}

const kubectl = 'k3s kubectl -n nixie';

async function readVolumeName(options: Readonly<ResetNixieOptions>): Promise<string | undefined> {
  const claim = await options.runRemote(
    `${kubectl} get pvc data-nixie-0 -o jsonpath={.spec.volumeName}`,
  );

  const volume = claim.stdout.trim();

  if (claim.exitCode !== 0 || !/^pvc-[0-9a-f-]+$/u.test(volume)) {
    options.printErr(`reset-nixie: cannot find nixie's data volume: ${claim.stderr.trim()}\n`);

    return undefined;
  }

  return volume;
}

// local-path names each volume's directory after its PV, its namespace and its claim
const dataDirPattern = /^\/var\/lib\/rancher\/k3s\/storage\/pvc-[0-9a-f-]+_nixie_data-nixie-0$/u;

// The path ends up in an rm, so anything outside k3s's local-path storage is refused
async function readDataDir(
  options: Readonly<ResetNixieOptions>,
  volume: string,
): Promise<string | undefined> {
  const pv = await options.runRemote(
    `k3s kubectl get pv ${volume} -o jsonpath={.spec.hostPath.path}`,
  );

  const dataDir = pv.stdout.trim();

  if (pv.exitCode !== 0) {
    options.printErr(`reset-nixie: cannot read ${volume}'s path: ${pv.stderr.trim()}\n`);

    return undefined;
  }

  if (!dataDirPattern.test(dataDir)) {
    options.printErr(
      `reset-nixie: refusing the data volume path ${JSON.stringify(dataDir)}: not nixie's local-path directory\n`,
    );

    return undefined;
  }

  return dataDir;
}

// the WAL and SHM files go first, so a stopped rm never leaves a stale WAL beside a fresh database
const dataFiles = [
  'nixie.db-wal',
  'nixie.db-shm',
  'nixie.db',
  'keys.db-wal',
  'keys.db-shm',
  'keys.db',
];

function buildListCommand(dataDir: string): string {
  const names = dataFiles.map((name) => `-name ${name}`).join(' -o ');

  return `find ${dataDir} -maxdepth 1 -type f \\( ${names} \\) -printf '%f %s bytes\\n' | sort`;
}

interface Step {
  readonly title: string;
  readonly command: string;

  // the step's stdout is the result the operator needs
  readonly printsOutput: boolean;
}

// The pod must be gone before the rm, because SQLite holds the WAL open while nixie runs
function planSteps(dataDir: string): Step[] {
  return [
    {
      title: 'scale statefulset/nixie to 0',
      command: `${kubectl} scale statefulset nixie --replicas=0`,
      printsOutput: false,
    },
    {
      title: 'wait for pod nixie-0 to stop',
      command: `${kubectl} wait --for=delete pod/nixie-0 --timeout=180s`,
      printsOutput: false,
    },
    {
      title: `remove ${dataFiles.join(', ')} from ${dataDir}`,
      command: `rm -f -- ${dataFiles.map((name) => `${dataDir}/${name}`).join(' ')}`,
      printsOutput: false,
    },
    {
      title: 'scale statefulset/nixie to 1',
      command: `${kubectl} scale statefulset nixie --replicas=1`,
      printsOutput: false,
    },
    {
      title: 'wait for nixie to be ready',
      command: `${kubectl} rollout status statefulset/nixie --timeout=600s`,
      printsOutput: false,
    },
    {
      title: 'print a fresh enrolment code',
      command: `${kubectl} exec nixie-0 -c nixie -- bun /app/main.js enrol-code`,
      printsOutput: true,
    },
  ];
}

function renderPlan(plan: Readonly<Plan>): string {
  const files =
    plan.present.length === 0
      ? ['  (none: the volume holds no data file)']
      : plan.present.map((line) => `  ${line}`);

  return [
    `nixie reset on geoffcloud: this deletes all of nixie's state and every device enrolment, and cannot be undone`,
    `data volume: ${plan.dataDir}`,
    'files to delete:',
    ...files,
    'steps:',
    ...plan.steps.map((step, index) => `  ${index + 1}. ${step.title}`),
    '',
  ].join('\n');
}

function printDryRunEnd(options: Readonly<ResetNixieOptions>): number {
  options.printOut('dry run: nothing changed; run again with --confirm to reset\n');

  return 0;
}

// Runs the steps in order and stops at the first failure, since each step needs the one before it
async function runSteps(
  options: Readonly<ResetNixieOptions>,
  steps: readonly Step[],
  index: number,
): Promise<number> {
  const step = steps[index];

  if (step === undefined) {
    return printDone(options);
  }

  options.printOut(`==> ${index + 1}. ${step.title}\n`);

  const result = await options.runRemote(step.command);

  if (result.exitCode !== 0) {
    return printFailure(
      options,
      `reset-nixie: step ${index + 1} failed (exit ${result.exitCode}): ${result.stderr.trim()}\nnixie may be stopped; run again with --confirm once the cause is fixed\n`,
      1,
    );
  }

  if (step.printsOutput) {
    options.printOut(result.stdout);
  }

  return runSteps(options, steps, index + 1);
}

function printDone(options: Readonly<ResetNixieOptions>): number {
  options.printOut('reset done: enter the code above at https://nixie.geoff.cloud\n');

  return 0;
}

async function runSSH(command: string): Promise<RemoteResult> {
  const proc = Bun.spawn(['ssh', 'root@geoffcloud', command], {
    stdin: 'ignore',
    stdout: 'pipe',
    stderr: 'pipe',
  });

  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);

  return { exitCode, stdout, stderr };
}

if (import.meta.main) {
  process.exitCode = await resetNixie({
    args: process.argv.slice(2),
    runRemote: runSSH,
    printOut: (text) => process.stdout.write(text),
    printErr: (text) => process.stderr.write(text),
  });
}

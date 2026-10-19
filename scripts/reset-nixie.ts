// Resets nixie's event log on geoffcloud through nixie's own reset command, which keeps every
// signed-in device signed in. Only --confirm changes anything: --dry-run lists the sessions the reset
// keeps and the steps, and no flag refuses before reaching the host.
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
      `reset-nixie: refusing to reset nixie without --confirm; --dry-run lists what it keeps\n${usage}`,
      1,
    );
  }

  const sessions = await readSessionCount(options);

  if (sessions === undefined) {
    return 1;
  }

  options.printOut(renderPlan(sessions));

  return mode === 'dry-run' ? printDryRunEnd(options) : runReset(options);
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

// nixie's documented host commands, run in nixie's container
const nixie = 'k3s kubectl -n nixie exec nixie-0 -c nixie -- nixie';

// Reads only: the live device sessions, which the reset keeps, from the running server
async function readSessionCount(options: Readonly<ResetNixieOptions>): Promise<number | undefined> {
  const listed = await options.runRemote(`${nixie} sessions`);

  const sessions = listed.exitCode === 0 ? parseSessions(listed.stdout) : undefined;

  if (sessions === undefined) {
    options.printErr(
      `reset-nixie: cannot list nixie's device sessions (exit ${listed.exitCode}): ${listed.stderr.trim()}\n`,
    );
  }

  return sessions;
}

function parseSessions(text: string): number | undefined {
  try {
    const sessions: unknown = JSON.parse(text);

    return Array.isArray(sessions) ? sessions.length : undefined;
  } catch {
    return undefined;
  }
}

const resetCommand = `${nixie} reset --keep-sessions --yes`;

function renderPlan(sessions: number): string {
  return [
    `nixie reset on geoffcloud: this removes every record, every memory, the conversation and every sandbox; only a restore from a backup undoes it`,
    `device sessions kept signed in: ${sessions}`,
    'steps:',
    `  1. ${resetCommand}`,
    '',
  ].join('\n');
}

function printDryRunEnd(options: Readonly<ResetNixieOptions>): number {
  options.printOut('dry run: nothing changed; run again with --confirm to reset\n');

  return 0;
}

// nixie answers once the reset finishes, then exits 0, and the kubelet starts it again
async function runReset(options: Readonly<ResetNixieOptions>): Promise<number> {
  options.printOut(`==> 1. ${resetCommand}\n`);

  const result = await options.runRemote(resetCommand);

  if (result.exitCode !== 0) {
    return printFailure(
      options,
      `reset-nixie: the reset failed (exit ${result.exitCode}): ${result.stdout.trim()} ${result.stderr.trim()}\nnixie's log holds the reason; run again with --confirm once the cause is fixed\n`,
      1,
    );
  }

  options.printOut(result.stdout);

  options.printOut(
    'reset done: nixie restarts now; bash scripts/check-nixie-ready.sh root@geoffcloud reports when it is ready\n',
  );

  return 0;
}

async function runSSH(command: string): Promise<RemoteResult> {
  const subprocess = Bun.spawn(['ssh', 'root@geoffcloud', command], {
    stdin: 'ignore',
    stdout: 'pipe',
    stderr: 'pipe',
  });

  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(subprocess.stdout).text(),
    new Response(subprocess.stderr).text(),
    subprocess.exited,
  ]);

  return { exitCode, stdout, stderr };
}

if (import.meta.main) {
  process.exitCode = await resetNixie({
    args: process.argv.slice(2),
    runRemote: runSSH,
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}

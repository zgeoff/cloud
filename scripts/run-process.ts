// The operator scripts run every subprocess through a Runner, so a test injects a stand-in and no
// script builds a shell command line here. It imports nothing outside Bun: atc's release job and
// the agent image's git archive run scripts from a clone without node_modules.
export interface RunOptions {
  // the whole of the child's stdin; without it, the child reads /dev/null
  readonly stdin?: Buffer;

  // the child gets SIGTERM after this long, as `timeout` sends it
  readonly timeoutMs?: number;
  readonly cwd?: string;

  // the child's whole environment; without it, the child inherits this process's
  readonly env?: Readonly<Record<string, string | undefined>>;
}

export interface RunResult {
  // a child killed by a signal exits 128 plus the signal's number, as bash reports it; a program
  // that is not installed exits 127
  readonly exitCode: number;
  readonly stdout: Buffer;
  readonly stderr: Buffer;
  readonly timedOut: boolean;
}

export type Runner = (argv: readonly string[], options?: RunOptions) => Promise<RunResult>;

// ten minutes, for a call that names no timeout of its own
const defaultTimeoutMs = 600_000;

// Runs one program with its argv as given: no shell parses it
export async function runProcess(
  argv: readonly string[],
  options: Readonly<RunOptions> = {},
): Promise<RunResult> {
  const timeoutMs = options.timeoutMs ?? defaultTimeoutMs;
  const spawned = trySpawn(argv, options);

  if (spawned instanceof Error) {
    return {
      exitCode: 127,
      stdout: Buffer.alloc(0),
      stderr: Buffer.from(`${argv[0] ?? ''}: ${spawned.message}\n`),
      timedOut: false,
    };
  }

  // the flag, not the signal, marks a timeout: a child can also die of its own SIGTERM
  let timedOut = false;

  const timer = setTimeout(() => {
    timedOut = true;

    spawned.kill('SIGTERM');
  }, timeoutMs);

  const [stdout, stderr] = await Promise.all([
    new Response(spawned.stdout).arrayBuffer(),
    new Response(spawned.stderr).arrayBuffer(),
    spawned.exited,
  ]);

  clearTimeout(timer);

  return {
    exitCode: getExitCode(spawned),
    stdout: Buffer.from(stdout),
    stderr: Buffer.from(stderr),
    timedOut,
  };
}

function trySpawn(argv: readonly string[], options: Readonly<RunOptions>) {
  try {
    return Bun.spawn([...argv], {
      stdin: options.stdin ?? 'ignore',
      stdout: 'pipe',
      stderr: 'pipe',
      ...(options.cwd === undefined ? {} : { cwd: options.cwd }),
      ...(options.env === undefined ? {} : { env: { ...options.env } }),
    });
  } catch (error) {
    // Bun throws when the program is missing, where bash prints "command not found"
    return error instanceof Error ? error : new Error(String(error));
  }
}

const signalNumbers: Readonly<Record<string, number>> = {
  SIGHUP: 1,
  SIGINT: 2,
  SIGQUIT: 3,
  SIGKILL: 9,
  SIGPIPE: 13,
  SIGTERM: 15,
};

function getExitCode(spawned: Readonly<{ exitCode: number | null; signalCode: string | null }>) {
  if (spawned.exitCode !== null) {
    return spawned.exitCode;
  }

  return 128 + (signalNumbers[spawned.signalCode ?? ''] ?? 0);
}

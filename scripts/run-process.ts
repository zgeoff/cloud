// It imports nothing outside Bun: the agent image's git archive runs scripts from a clone without
// node_modules.

export interface RunOptions {
  // the whole of the child's stdin; without it, the child reads /dev/null
  readonly stdin?: Buffer;

  readonly timeoutMs?: number;

  // the child and its descendants get SIGTERM when this aborts, which no timeout reports
  readonly signal?: AbortSignal;

  // the child and its descendants get SIGKILL when this aborts, for one that outlives its SIGTERM
  readonly forceStop?: AbortSignal;
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

export async function runProcess(
  argv: readonly string[],
  options: Readonly<RunOptions> = {},
): Promise<RunResult> {
  // A child that the caller can stop leads a process group of its own, so the stop reaches the
  // descendants that hold its pipes. Any other child stays in this process's group, where a
  // terminal's Ctrl-C reaches it.
  const ownGroup = options.signal !== undefined || options.forceStop !== undefined;
  const spawned = trySpawn(argv, options, ownGroup);

  if (spawned instanceof Error) {
    return {
      exitCode: 127,
      stdout: Buffer.alloc(0),
      stderr: Buffer.from(`${argv[0] ?? ''}: ${spawned.message}\n`),
      timedOut: false,
    };
  }

  const stops = subscribeToStops({ spawned, ownGroup }, options);

  const [stdout, stderr] = await Promise.all([
    readPipe(spawned.stdout, stops.release),
    readPipe(spawned.stderr, stops.release),
    spawned.exited,
  ]);

  stops.unsubscribe();

  return {
    exitCode: getExitCode(spawned),
    stdout,
    stderr,
    timedOut: stops.hasTimedOut(),
  };
}

function trySpawn(argv: readonly string[], options: Readonly<RunOptions>, ownGroup: boolean) {
  try {
    return Bun.spawn([...argv], {
      stdin: options.stdin ?? 'ignore',
      stdout: 'pipe',
      stderr: 'pipe',

      // Bun starts a detached child with setsid, which makes it the leader of a new group
      detached: ownGroup,
      ...(options.cwd === undefined ? {} : { cwd: options.cwd }),
      ...(options.env === undefined ? {} : { env: { ...options.env } }),
    });
  } catch (error) {
    // Bun throws when the program is missing, where bash prints "command not found"
    return error instanceof Error ? error : new Error(String(error));
  }
}

interface Child {
  readonly spawned: Readonly<Pick<Bun.Subprocess, 'pid' | 'kill' | 'exited'>>;
  readonly ownGroup: boolean;
}

function sendSignal(child: Readonly<Child>, signal: 'SIGTERM' | 'SIGKILL') {
  if (!child.ownGroup) {
    child.spawned.kill(signal);

    return;
  }

  try {
    process.kill(-child.spawned.pid, signal);
  } catch {
    // ESRCH: every process of the group has exited
  }
}

const defaultTimeoutMs = 600_000;

// the group's pipes close as SIGKILL ends its processes; one still open this long after the child
// exits belongs to a descendant that left the group
const releaseDelayMs = 100;

function subscribeToStops(child: Readonly<Child>, options: Readonly<RunOptions>) {
  const release = new AbortController();

  // the flag, not the signal, marks a timeout: a child can also die of its own SIGTERM
  let timedOut = false;

  const timer = setTimeout(() => {
    timedOut = true;

    sendSignal(child, 'SIGTERM');
  }, options.timeoutMs ?? defaultTimeoutMs);

  const onStop = () => {
    sendSignal(child, 'SIGTERM');
  };

  const onForceStop = () => {
    sendSignal(child, 'SIGKILL');

    // release frees the pipes that a descendant outside the group holds
    void stopReadsAfterExit(child, release);
  };

  subscribeToAbort(options.signal, onStop);
  subscribeToAbort(options.forceStop, onForceStop);

  return {
    release: release.signal,
    hasTimedOut: () => timedOut,
    unsubscribe: () => {
      clearTimeout(timer);
      options.signal?.removeEventListener('abort', onStop);
      options.forceStop?.removeEventListener('abort', onForceStop);
    },
  };
}

async function stopReadsAfterExit(child: Readonly<Child>, release: Readonly<AbortController>) {
  await child.spawned.exited;

  await Bun.sleep(releaseDelayMs);

  release.abort();
}

function subscribeToAbort(signal: AbortSignal | undefined, listener: () => void) {
  if (signal?.aborted === true) {
    listener();
  } else {
    signal?.addEventListener('abort', listener, { once: true });
  }
}

async function readPipe(pipe: ReadableStream<Uint8Array>, release: AbortSignal) {
  const reader = pipe.getReader();
  const chunks: Uint8Array[] = [];

  const onRelease = () => {
    void reader.cancel();
  };

  subscribeToAbort(release, onRelease);

  try {
    for (let read = await reader.read(); !read.done; read = await reader.read()) {
      chunks.push(read.value);
    }
  } finally {
    release.removeEventListener('abort', onRelease);
  }

  return Buffer.concat(chunks);
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

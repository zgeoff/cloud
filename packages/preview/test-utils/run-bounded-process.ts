interface BoundedChild {
  readonly pid: number;
  readonly exited: Promise<number>;
  readonly stdout: ReadableStream<Uint8Array>;
  readonly stderr: ReadableStream<Uint8Array>;
}

interface BoundedSpawnOptions {
  readonly cwd?: string;
  readonly env?: Record<string, string>;
}

export interface BoundedProcessDeps {
  readonly spawn: (argv: readonly string[], options: BoundedSpawnOptions) => BoundedChild;
  readonly killGroup: (pid: number) => void;
  readonly readGroup: (pid: number) => Promise<string>;
  readonly sleep: (durationMs: number) => Promise<void>;
  readonly now: () => number;
}

export interface BoundedProcessOptions {
  readonly name: string;
  readonly argv: readonly string[];
  readonly timeoutMs: number;
  readonly cwd?: string;
  readonly env?: Record<string, string>;
}

export interface BoundedProcessResult {
  readonly exitCode: number;
  readonly stdout: string;
  readonly stderr: string;
}

export async function runBoundedProcess(
  deps: BoundedProcessDeps,
  options: BoundedProcessOptions,
): Promise<BoundedProcessResult> {
  const startedAt = deps.now();

  const child = deps.spawn(options.argv, {
    ...(options.cwd === undefined ? {} : { cwd: options.cwd }),
    ...(options.env === undefined ? {} : { env: options.env }),
  });

  const exit = trackSettled(child.exited);
  const stdout = readStreamText(child.stdout);
  const stderr = readStreamText(child.stderr);
  const finished = Promise.all([exit.done, stdout.done, stderr.done]);

  // a grandchild that outlives the child keeps the pipes open, so the bound covers the pipes too
  const outcome = await Promise.race([
    finished.then(([exitCode]) => ({ exitCode })),
    deps.sleep(options.timeoutMs).then(() => null),
  ]);

  if (outcome === null) {
    const elapsedMs = Math.round(deps.now() - startedAt);

    // read before the kill, which ends the group and settles every part
    const pending = Object.entries({ exit, stdout, stderr })
      .filter(([, tracked]) => !tracked.isSettled())
      .map(([part]) => part);

    const group = await deps.readGroup(child.pid);

    deps.killGroup(child.pid);

    await finished;

    throw new Error(
      `${options.name} did not finish within ${String(options.timeoutMs)} ms (stopped after ${String(elapsedMs)} ms, waiting on ${pending.join(', ')}); stdout: ${stdout.read()}; stderr: ${stderr.read()}; process group:\n${group}`,
    );
  }

  return { exitCode: outcome.exitCode, stdout: stdout.read(), stderr: stderr.read() };
}

function trackSettled<T>(promise: Promise<T>) {
  let settled = false;

  const done = (async () => {
    try {
      return await promise;
    } finally {
      settled = true;
    }
  })();

  return { done, isSettled: () => settled };
}

function readStreamText(stream: ReadableStream<Uint8Array>) {
  const decoder = new TextDecoder();

  let text = '';

  const reading = trackSettled(
    (async () => {
      for await (const chunk of stream) {
        text += decoder.decode(chunk, { stream: true });
      }
    })(),
  );

  return { ...reading, read: () => text };
}

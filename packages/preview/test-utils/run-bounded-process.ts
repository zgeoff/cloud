import { once } from 'node:events';

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
  options: BoundedProcessOptions,
): Promise<BoundedProcessResult> {
  const signal = AbortSignal.timeout(options.timeoutMs);
  const startedAt = performance.now();

  const child = Bun.spawn([...options.argv], {
    ...(options.cwd === undefined ? {} : { cwd: options.cwd }),
    ...(options.env === undefined ? {} : { env: options.env }),
    stdin: 'ignore',
    stdout: 'pipe',
    stderr: 'pipe',
    detached: true,
  });

  const stdout = readStreamText(child.stdout);
  const stderr = readStreamText(child.stderr);
  const finished = Promise.all([child.exited, stdout.done, stderr.done]);

  // a grandchild that outlives the child keeps the pipes open, so the bound covers the pipes too,
  // and the kill reaches the child's whole process group
  const outcome = await Promise.race([
    finished.then(([exitCode]) => ({ exitCode })),
    once(signal, 'abort').then(() => null),
  ]);

  if (outcome === null) {
    process.kill(-child.pid, 'SIGKILL');

    const elapsedMs = Math.round(performance.now() - startedAt);

    throw new Error(
      `${options.name} did not finish within ${String(options.timeoutMs)} ms (stopped after ${String(elapsedMs)} ms); stderr: ${stderr.read()}`,
    );
  }

  return { exitCode: outcome.exitCode, stdout: stdout.read(), stderr: stderr.read() };
}

function readStreamText(stream: ReadableStream<Uint8Array>) {
  const decoder = new TextDecoder();

  let text = '';

  const done = (async () => {
    for await (const chunk of stream) {
      text += decoder.decode(chunk, { stream: true });
    }
  })();

  return { done, read: () => text };
}

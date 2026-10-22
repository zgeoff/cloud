import { mkdirSync } from 'node:fs';
import { rm } from 'node:fs/promises';
import { join } from 'node:path';
import type { Subprocess } from 'bun';
import { z } from 'zod';
import type { SpendSettings } from './types.ts';

export interface SpendProxies {
  // the loopback origin of the imp's counting proxy, which starts when none runs
  readonly readOrigin: (imp: string) => Promise<string>;

  // stops the imp's proxy and removes its config and its count
  readonly removeProxy: (imp: string) => Promise<void>;

  // stops each proxy that went unused for the idle time, and keeps its count on disk
  readonly removeIdle: () => Promise<void>;
  readonly removeAll: () => Promise<void>;
}

export interface SpendProxyDeps {
  readonly now: () => Date;
  readonly log: (line: string) => void;
}

interface RunningProxy {
  readonly process: Subprocess<'ignore', 'pipe', 'inherit'>;
  readonly origin: string;
  lastUsedMs: number;
}

export function createSpendProxies(settings: SpendSettings, deps: SpendProxyDeps): SpendProxies {
  mkdirSync(settings.directory, { recursive: true, mode: 0o700 });

  // a start in flight is shared, so two requests at once start one proxy
  const proxies = new Map<string, Promise<RunningProxy>>();

  const stopProxy = async (imp: string): Promise<void> => {
    const pending = proxies.get(imp);

    proxies.delete(imp);

    const running = await pending?.catch(() => null);

    running?.process.kill();

    await running?.process.exited;
  };

  const readRunning = async (imp: string): Promise<RunningProxy> => {
    const pending = proxies.get(imp) ?? startProxy(settings, deps, imp);

    proxies.set(imp, pending);

    try {
      const running = await pending;

      // a proxy that exited on its own starts again, from the count it left on disk
      if (running.process.exitCode !== null || running.process.signalCode !== null) {
        proxies.delete(imp);

        return await readRunning(imp);
      }

      return running;
    } catch (error) {
      proxies.delete(imp);
      throw error;
    }
  };

  return {
    readOrigin: async (imp) => {
      const running = await readRunning(imp);

      running.lastUsedMs = deps.now().getTime();

      return running.origin;
    },
    removeProxy: async (imp) => {
      await stopProxy(imp);

      const paths = buildProxyPaths(settings, imp);

      await Promise.all(
        [paths.config, paths.store, `${paths.store}.part`].map((path) => rm(path, { force: true })),
      );
    },
    removeIdle: async () => {
      const cutoffMs = deps.now().getTime() - settings.idleMs;

      const settled = await Promise.all(
        [...proxies].map(async ([imp, pending]) => ({
          imp,
          running: await pending.catch(() => null),
        })),
      );

      const idle = settled.filter(
        (entry) => entry.running !== null && entry.running.lastUsedMs < cutoffMs,
      );

      await Promise.all(idle.map((entry) => stopProxy(entry.imp)));
    },
    removeAll: async () => {
      await Promise.all([...proxies.keys()].map((imp) => stopProxy(imp)));
    },
  };
}

const startTimeoutMs = 10_000;

async function startProxy(
  settings: SpendSettings,
  deps: SpendProxyDeps,
  imp: string,
): Promise<RunningProxy> {
  const paths = buildProxyPaths(settings, imp);

  // the route's ID is the imp's name, so the path the broker sends on reaches the proxy unchanged
  await Bun.write(
    paths.config,
    JSON.stringify({
      listen: { hostname: '127.0.0.1', port: 0 },
      store: paths.store,
      limits: { dollars: settings.limitDollars },
      routes: {
        [imp]: { upstream: settings.upstream, model: settings.model, prices: settings.prices },
      },
    }),
  );

  const child = Bun.spawn([settings.proxyPath, '--config', paths.config], {
    stdin: 'ignore',
    stdout: 'pipe',
    stderr: 'inherit',
  });

  const lines = readLines(child.stdout);
  const timeout = AbortSignal.timeout(startTimeoutMs);

  const port = await readStartedPort(lines, timeout);

  if (port === null) {
    child.kill();

    await child.exited;

    throw new Error(`the counting proxy for ${imp} did not start`);
  }

  // the proxy writes each later line to the same pipe, which must keep draining
  void logLines(lines, imp, deps);
  void logExit(child, imp, deps);

  return { process: child, origin: `http://127.0.0.1:${port}`, lastUsedMs: deps.now().getTime() };
}

function buildProxyPaths(
  settings: SpendSettings,
  imp: string,
): { readonly config: string; readonly store: string } {
  return {
    config: join(settings.directory, `${imp}.json`),
    store: join(settings.directory, `${imp}.count.json`),
  };
}

async function* readLines(stream: ReadableStream<Uint8Array>): AsyncGenerator<string> {
  const decoder = new TextDecoder();

  let pending = '';

  for await (const chunk of stream) {
    pending += decoder.decode(chunk, { stream: true });

    const lines = pending.split('\n');

    pending = lines.pop() ?? '';
    yield* lines;
  }
}

// the proxy names its port in its start line, so each proxy takes a free one from the kernel
const startedLineSchema = z.looseObject({
  event: z.literal('proxy.started'),
  port: z.int().min(1).max(65_535),
});

// reads with next() rather than for await, because leaving a for await early closes the generator,
// and the log still needs its later lines
async function readStartedPort(
  lines: AsyncGenerator<string>,
  timeout: AbortSignal,
): Promise<number | null> {
  const timedOut = new Promise<null>((resolve) => {
    timeout.addEventListener('abort', () => {
      resolve(null);
    });
  });

  for (;;) {
    const next = await Promise.race([lines.next(), timedOut]);

    if (next === null || next.done === true) {
      return null;
    }

    const started = startedLineSchema.safeParse(parseJSONOrNull(next.value));

    if (started.success) {
      return started.data.port;
    }
  }
}

function parseJSONOrNull(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

async function logLines(
  lines: AsyncGenerator<string>,
  imp: string,
  deps: SpendProxyDeps,
): Promise<void> {
  for await (const line of lines) {
    deps.log(`${imp}: ${line}`);
  }
}

async function logExit(
  child: Subprocess<'ignore', 'pipe', 'inherit'>,
  imp: string,
  deps: SpendProxyDeps,
): Promise<void> {
  const code = await child.exited;

  deps.log(`${imp}: the counting proxy exited ${String(code)}`);
}

import { join } from 'node:path';
import { z } from 'zod';
import type { ProxyProcess, SpendProxyIO } from './build-spend-proxy-io.ts';
import { countingProxyConfigSchema } from './counting-proxy-config-schema.ts';
import type { SpendSettings } from './types.ts';

export interface ProxyHold {
  readonly origin: string;
  readonly release: () => void;
}

export interface SpendProxies {
  // the loopback origin of the imp's counting proxy, which starts when none runs; the idle sweep
  // leaves the proxy alone until the call releases its hold
  readonly holdProxy: (imp: string) => Promise<ProxyHold>;

  // stops the imp's proxy and removes its config and its count
  readonly removeProxy: (imp: string) => Promise<void>;

  // stops each proxy that holds no call and went unused for the idle time, and keeps its count on
  // disk
  readonly removeIdle: () => Promise<void>;
  readonly removeAll: () => Promise<void>;
}

export interface SpendProxyDeps {
  readonly now: () => Date;
  readonly log: (line: string) => void;
  readonly io: SpendProxyIO;
}

interface RunningProxy {
  readonly process: ProxyProcess;
  readonly origin: string;
}

// One entry per imp, which a hold counts on before it waits for the start, so the idle sweep
// sees every call that has asked for the proxy, started or not.
interface ProxyEntry {
  pending: Promise<RunningProxy>;
  holds: number;
  lastUsedMs: number;
}

export function createSpendProxies(settings: SpendSettings, deps: SpendProxyDeps): SpendProxies {
  deps.io.createDirectory(settings.directory);

  const entries = new Map<string, ProxyEntry>();

  // the proxy of an imp whose stop is under way, which a new start waits out, so two proxies never
  // write one count
  const stopping = new Map<string, Promise<void>>();

  const startAfterStop = async (imp: string): Promise<RunningProxy> => {
    await stopping.get(imp);

    return startProxy(settings, deps, imp);
  };

  const readEntry = (imp: string): ProxyEntry => {
    const existing = entries.get(imp);

    if (existing !== undefined) {
      return existing;
    }

    const entry = {
      pending: startAfterStop(imp),
      holds: 0,
      lastUsedMs: deps.now().getTime(),
    };

    entries.set(imp, entry);

    return entry;
  };

  const killProxy = async (entry: ProxyEntry | undefined): Promise<void> => {
    const running = await entry?.pending.catch(() => null);

    running?.process.kill();

    await running?.process.exited;
  };

  const stopProxy = async (imp: string): Promise<void> => {
    const entry = entries.get(imp);

    entries.delete(imp);

    const stopped = killProxy(entry);

    stopping.set(imp, stopped);

    await stopped;

    if (stopping.get(imp) === stopped) {
      stopping.delete(imp);
    }
  };

  const readRunning = async (imp: string, entry: ProxyEntry): Promise<RunningProxy> => {
    const pending = entry.pending;

    try {
      const running = await pending;

      // A proxy that exited on its own starts again, from the count it left on disk. Calls that
      // wait on one start share the start that replaces it.
      if (running.process.exitCode !== null || running.process.signalCode !== null) {
        if (entry.pending === pending) {
          entry.pending = startProxy(settings, deps, imp);
        }

        return await readRunning(imp, entry);
      }

      return running;
    } catch (error) {
      if (entries.get(imp) === entry && entry.pending === pending) {
        entries.delete(imp);
      }

      throw error;
    }
  };

  return {
    holdProxy: async (imp) => {
      const entry = readEntry(imp);

      entry.holds += 1;

      const running = await readRunning(imp, entry).catch((error: unknown) => {
        entry.holds -= 1;
        throw error;
      });

      entry.lastUsedMs = deps.now().getTime();

      let released = false;

      return {
        origin: running.origin,
        release: () => {
          if (released) {
            return;
          }

          released = true;
          entry.holds -= 1;
          entry.lastUsedMs = deps.now().getTime();
        },
      };
    },
    removeProxy: async (imp) => {
      await stopProxy(imp);

      const paths = buildProxyPaths(settings, imp);

      await Promise.all(
        [paths.config, paths.store, `${paths.store}.part`].map((path) => deps.io.removeFile(path)),
      );
    },
    removeIdle: async () => {
      const cutoffMs = deps.now().getTime() - settings.idleMs;

      const settled = await Promise.all(
        [...entries].map(async ([imp, entry]) => ({
          imp,
          entry,
          running: await entry.pending.catch(() => null),
        })),
      );

      // the check and the stop run with no wait between them, so a hold taken after the check
      // finds the entry gone and starts a proxy of its own
      const idle = settled.filter(
        (each) =>
          entries.get(each.imp) === each.entry &&
          each.running !== null &&
          each.entry.holds === 0 &&
          each.entry.lastUsedMs < cutoffMs,
      );

      await Promise.all(idle.map((each) => stopProxy(each.imp)));
    },
    removeAll: async () => {
      await Promise.all([...entries.keys()].map((imp) => stopProxy(imp)));
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
  const config = countingProxyConfigSchema.parse({
    listen: { hostname: '127.0.0.1', port: 0 },
    store: paths.store,
    limits: { dollars: settings.limitDollars },
    routes: {
      [imp]: { upstream: settings.upstream, model: settings.model, prices: settings.prices },
    },
  });

  await deps.io.writeFile(paths.config, JSON.stringify(config));

  const child = deps.io.runProxy([settings.proxyPath, '--config', paths.config]);
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

  return { process: child, origin: `http://127.0.0.1:${port}` };
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

async function logExit(child: ProxyProcess, imp: string, deps: SpendProxyDeps): Promise<void> {
  const code = await child.exited;

  deps.log(`${imp}: the counting proxy exited ${String(code)}`);
}

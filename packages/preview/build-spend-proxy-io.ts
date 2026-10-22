import { mkdirSync } from 'node:fs';
import { rm } from 'node:fs/promises';
import type { Subprocess } from 'bun';

export type ProxyProcess = Subprocess<'ignore', 'pipe', 'inherit'>;

// the files and processes the proxy manager touches, which the service takes from the host
export interface SpendProxyIO {
  readonly createDirectory: (path: string) => void;
  readonly writeFile: (path: string, text: string) => Promise<void>;
  readonly removeFile: (path: string) => Promise<void>;
  readonly runProxy: (argv: readonly string[]) => ProxyProcess;
}

export function buildSpendProxyIO(): SpendProxyIO {
  return {
    createDirectory: (path) => {
      mkdirSync(path, { recursive: true, mode: 0o700 });
    },
    writeFile: async (path, text) => {
      await Bun.write(path, text);
    },
    removeFile: (path) => rm(path, { force: true }),
    runProxy: (argv) =>
      Bun.spawn([...argv], { stdin: 'ignore', stdout: 'pipe', stderr: 'inherit' }),
  };
}

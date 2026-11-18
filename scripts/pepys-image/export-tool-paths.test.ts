import { expect, mock, onTestFinished, test } from 'bun:test';
import { chmod, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { exportToolPaths } from './export-tool-paths.ts';

async function setupTest(tools: readonly string[]) {
  const directory = await mkdtemp(join(tmpdir(), 'export-tool-paths-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const bin = join(directory, 'bin');
  const githubEnv = join(directory, 'github-env');

  await Bun.write(join(bin, '.keep'), '');

  await writeFile(githubEnv, 'EXISTING=1\n');

  for (const tool of tools) {
    await writeFile(join(bin, tool), '#!/bin/sh\n');
    await chmod(join(bin, tool), 0o755);
  }

  const printErr = mock<(text: string) => void>();
  const env = { PATH: bin, GITHUB_ENV: githubEnv };

  return { bin, githubEnv, env, printErr };
}

test('it appends the path of each tool to the GITHUB_ENV file', async () => {
  const ctx = await setupTest(['zig', 'wasm-tools']);
  const status = await exportToolPaths(ctx);

  expect(status).toBe(0);

  const written = await readFile(ctx.githubEnv, 'utf8');

  expect(written).toBe(
    `EXISTING=1\nPEPYS_ZIG_BIN=${join(ctx.bin, 'zig')}\nPEPYS_WASM_TOOLS_BIN=${join(ctx.bin, 'wasm-tools')}\n`,
  );

  expect(ctx.printErr.mock.calls).toStrictEqual([]);
});

test('it fails and writes nothing when a tool is missing from PATH', async () => {
  const ctx = await setupTest(['zig']);
  const status = await exportToolPaths(ctx);

  expect(status).toBe(1);

  const written = await readFile(ctx.githubEnv, 'utf8');

  expect(written).toBe('EXISTING=1\n');
  expect(ctx.printErr.mock.calls).toStrictEqual([['export-tool-paths: not on PATH: wasm-tools\n']]);
});

test('it names every missing tool', async () => {
  const ctx = await setupTest([]);
  const status = await exportToolPaths(ctx);

  expect(status).toBe(1);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['export-tool-paths: not on PATH: zig, wasm-tools\n'],
  ]);
});

test('it fails when GITHUB_ENV is not set', async () => {
  const ctx = await setupTest(['zig', 'wasm-tools']);
  const status = await exportToolPaths({ env: { PATH: ctx.bin }, printErr: ctx.printErr });

  expect(status).toBe(2);
  expect(ctx.printErr.mock.calls).toStrictEqual([['export-tool-paths: GITHUB_ENV is not set\n']]);
});

import { expect, mock, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { $ } from 'bun';
import { exportToolPaths } from './export-tool-paths.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'export-tool-paths-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const bin = join(directory, 'bin');
  const scriptPath = join(import.meta.dir, 'export-tool-paths.ts');
  const githubEnv = join(directory, 'github-env');

  await mkdir(bin);

  const printErr = mock<(text: string) => void>();

  return { bin, githubEnv, printErr, scriptPath };
}

test('it appends the path of each tool to the GITHUB_ENV file', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.bin, 'zig'), '#!/bin/sh\n', { mode: 0o755 });
  await writeFile(join(ctx.bin, 'wasm-tools'), '#!/bin/sh\n', { mode: 0o755 });
  await writeFile(ctx.githubEnv, 'EXISTING=1\n');

  const status = await exportToolPaths({
    env: { PATH: ctx.bin, GITHUB_ENV: ctx.githubEnv },
    printErr: ctx.printErr,
  });

  expect(status).toBe(0);

  const written = await readFile(ctx.githubEnv, 'utf8');

  expect(written).toBe(
    `EXISTING=1\nPEPYS_ZIG_BIN=${join(ctx.bin, 'zig')}\nPEPYS_WASM_TOOLS_BIN=${join(ctx.bin, 'wasm-tools')}\n`,
  );

  expect(ctx.printErr.mock.calls).toStrictEqual([]);
});

test('it fails and writes nothing when a tool is missing from PATH', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.bin, 'zig'), '#!/bin/sh\n', { mode: 0o755 });
  await writeFile(ctx.githubEnv, 'EXISTING=1\n');

  const status = await exportToolPaths({
    env: { PATH: ctx.bin, GITHUB_ENV: ctx.githubEnv },
    printErr: ctx.printErr,
  });

  expect(status).toBe(1);

  const written = await readFile(ctx.githubEnv, 'utf8');

  expect(written).toBe('EXISTING=1\n');
  expect(ctx.printErr.mock.calls).toStrictEqual([['export-tool-paths: not on PATH: wasm-tools\n']]);
});

test('it names every missing tool', async () => {
  const ctx = await setupTest();

  await writeFile(ctx.githubEnv, 'EXISTING=1\n');

  const status = await exportToolPaths({
    env: { PATH: ctx.bin, GITHUB_ENV: ctx.githubEnv },
    printErr: ctx.printErr,
  });

  expect(status).toBe(1);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['export-tool-paths: not on PATH: zig, wasm-tools\n'],
  ]);
});

test('it fails when GITHUB_ENV is not set', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.bin, 'zig'), '#!/bin/sh\n', { mode: 0o755 });
  await writeFile(join(ctx.bin, 'wasm-tools'), '#!/bin/sh\n', { mode: 0o755 });

  const status = await exportToolPaths({ env: { PATH: ctx.bin }, printErr: ctx.printErr });

  expect(status).toBe(2);
  expect(ctx.printErr.mock.calls).toStrictEqual([['export-tool-paths: GITHUB_ENV is not set\n']]);
});

test('it exports both tool paths when run as a script', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.bin, 'zig'), '#!/bin/sh\n', { mode: 0o755 });
  await writeFile(join(ctx.bin, 'wasm-tools'), '#!/bin/sh\n', { mode: 0o755 });
  await writeFile(ctx.githubEnv, 'EXISTING=1\n');

  const result = await $`${process.execPath} ${ctx.scriptPath}`
    .env({ PATH: ctx.bin, GITHUB_ENV: ctx.githubEnv })
    .nothrow()
    .quiet();

  expect(result.exitCode).toBe(0);
  expect(result.stderr.toString()).toBe('');

  const written = await readFile(ctx.githubEnv, 'utf8');

  expect(written).toBe(
    `EXISTING=1\nPEPYS_ZIG_BIN=${join(ctx.bin, 'zig')}\nPEPYS_WASM_TOOLS_BIN=${join(ctx.bin, 'wasm-tools')}\n`,
  );
});

test('it exits non-zero with a message when run as a script with a tool missing', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.bin, 'zig'), '#!/bin/sh\n', { mode: 0o755 });
  await writeFile(ctx.githubEnv, 'EXISTING=1\n');

  const result = await $`${process.execPath} ${ctx.scriptPath}`
    .env({ PATH: ctx.bin, GITHUB_ENV: ctx.githubEnv })
    .nothrow()
    .quiet();

  expect(result.exitCode).toBe(1);
  expect(result.stderr.toString()).toBe('export-tool-paths: not on PATH: wasm-tools\n');

  const written = await readFile(ctx.githubEnv, 'utf8');

  expect(written).toBe('EXISTING=1\n');
});

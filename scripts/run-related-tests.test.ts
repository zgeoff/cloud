import { expect, onTestFinished, test } from 'bun:test';
import { mkdirSync, writeFileSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { collectRelatedTests } from './run-related-tests.ts';

test('it selects a test file that exists', async () => {
  const ctx = await setupTest();

  writeFileSync(join(ctx.directory, 'src/a.test.ts'), '');

  expect(collectRelatedTests(['src/a.test.ts'], ctx.directory)).toStrictEqual(['src/a.test.ts']);
});

test('it selects the sibling test of a source file', async () => {
  const ctx = await setupTest();

  writeFileSync(join(ctx.directory, 'src/a.ts'), '');
  writeFileSync(join(ctx.directory, 'src/a.test.ts'), '');

  expect(collectRelatedTests(['src/a.ts'], ctx.directory)).toStrictEqual(['src/a.test.ts']);
});

test('it skips a source file with no sibling test and a test file that was deleted', async () => {
  const ctx = await setupTest();

  writeFileSync(join(ctx.directory, 'src/a.ts'), '');

  expect(collectRelatedTests(['src/a.ts', 'src/gone.test.ts'], ctx.directory)).toStrictEqual([]);
});

test('it skips a declaration file even when a test sits beside it', async () => {
  const ctx = await setupTest();

  writeFileSync(join(ctx.directory, 'src/types.d.ts'), '');
  writeFileSync(join(ctx.directory, 'src/types.d.test.ts'), '');

  expect(collectRelatedTests(['src/types.d.ts'], ctx.directory)).toStrictEqual([]);
});

test('it skips files that are not TypeScript', async () => {
  const ctx = await setupTest();

  writeFileSync(join(ctx.directory, 'src/a.md'), '');
  writeFileSync(join(ctx.directory, 'src/a.test.ts'), '');

  expect(collectRelatedTests(['src/a.md', 'README.md'], ctx.directory)).toStrictEqual([]);
});

test('it keeps the order of the paths and drops duplicates', async () => {
  const ctx = await setupTest();

  writeFileSync(join(ctx.directory, 'src/b.ts'), '');
  writeFileSync(join(ctx.directory, 'src/b.test.ts'), '');
  writeFileSync(join(ctx.directory, 'src/a.test.ts'), '');

  expect(
    collectRelatedTests(['src/b.ts', 'src/a.test.ts', 'src/b.test.ts'], ctx.directory),
  ).toStrictEqual(['src/b.test.ts', 'src/a.test.ts']);
});

test('it exits 0 and says so when no path has a related test', async () => {
  const ctx = await setupTest();

  const run = Bun.spawnSync(
    [process.execPath, join(import.meta.dir, 'run-related-tests.ts'), 'src/a.ts'],
    { cwd: ctx.directory },
  );

  expect(run.exitCode).toBe(0);
  expect(run.stdout.toString()).toBe('run-related-tests: no related tests\n');
});

test('it runs the related test through the test script and exits 0 when it passes', async () => {
  const ctx = await setupTest();

  writeFileSync(
    join(ctx.directory, 'package.json'),
    JSON.stringify({ scripts: { test: 'bun test' } }),
  );

  writeFileSync(
    join(ctx.directory, 'src/a.test.ts'),
    "import { expect, test } from 'bun:test';\n\ntest('it adds', () => {\n  expect(1 + 1).toBe(2);\n});\n",
  );

  const run = Bun.spawnSync(
    [process.execPath, join(import.meta.dir, 'run-related-tests.ts'), 'src/a.ts'],
    { cwd: ctx.directory },
  );

  expect(run.exitCode).toBe(0);
  expect(run.stderr.toString()).toInclude('1 pass');
});

test('it exits with the failing code when the related test fails', async () => {
  const ctx = await setupTest();

  writeFileSync(
    join(ctx.directory, 'package.json'),
    JSON.stringify({ scripts: { test: 'bun test' } }),
  );

  writeFileSync(
    join(ctx.directory, 'src/a.test.ts'),
    "import { expect, test } from 'bun:test';\n\ntest('it adds', () => {\n  expect(1 + 1).toBe(3);\n});\n",
  );

  const run = Bun.spawnSync(
    [process.execPath, join(import.meta.dir, 'run-related-tests.ts'), 'src/a.test.ts'],
    { cwd: ctx.directory },
  );

  expect(run.exitCode).toBe(1);
});

test('it runs a test inside a package with its own bunfig.toml from that package, under its preload', async () => {
  const ctx = await setupTest();

  writeFileSync(
    join(ctx.directory, 'package.json'),
    JSON.stringify({ scripts: { test: 'exit 3' } }),
  );

  mkdirSync(join(ctx.directory, 'src/pkg'));
  writeFileSync(join(ctx.directory, 'src/pkg/bunfig.toml'), '[test]\npreload = ["./preload.ts"]\n');

  writeFileSync(
    join(ctx.directory, 'src/pkg/preload.ts'),
    "process.env['PKG_PRELOAD'] = 'loaded';\n",
  );

  writeFileSync(
    join(ctx.directory, 'src/pkg/a.test.ts'),
    "import { expect, test } from 'bun:test';\n\ntest('it sees the preload', () => {\n  expect(process.env['PKG_PRELOAD']).toBe('loaded');\n});\n",
  );

  const run = Bun.spawnSync(
    [process.execPath, join(import.meta.dir, 'run-related-tests.ts'), 'src/pkg/a.test.ts'],
    { cwd: ctx.directory },
  );

  expect(run.exitCode).toBe(0);
  expect(run.stderr.toString()).toInclude('1 pass');
});

test('it stops at the first failing run and exits with its failing code', async () => {
  const ctx = await setupTest();

  writeFileSync(
    join(ctx.directory, 'package.json'),
    JSON.stringify({ scripts: { test: 'bun test' } }),
  );

  mkdirSync(join(ctx.directory, 'src/pkg'));
  writeFileSync(join(ctx.directory, 'src/pkg/bunfig.toml'), '');

  writeFileSync(
    join(ctx.directory, 'src/a.test.ts'),
    "import { expect, test } from 'bun:test';\n\ntest('it adds', () => {\n  expect(1 + 1).toBe(3);\n});\n",
  );

  writeFileSync(
    join(ctx.directory, 'src/pkg/a.test.ts'),
    "import { expect, test } from 'bun:test';\n\ntest('it adds', () => {\n  expect(1 + 1).toBe(2);\n});\n",
  );

  const run = Bun.spawnSync(
    [
      process.execPath,
      join(import.meta.dir, 'run-related-tests.ts'),
      'src/a.test.ts',
      'src/pkg/a.test.ts',
    ],
    { cwd: ctx.directory },
  );

  expect(run.exitCode).toBe(1);
  expect(run.stderr.toString()).not.toInclude('1 pass');
});

// A temp directory standing in for a repo root.
async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'run-related-tests-'));

  onTestFinished(async () => {
    await rm(directory, { recursive: true, force: true });
  });

  mkdirSync(join(directory, 'src'));

  return { directory };
}

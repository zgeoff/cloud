// a check test writes every pin file and the table it compares them with, so its body is long
/* oxlint-disable max-statements */
import { expect, mock, onTestFinished, test } from 'bun:test';
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { checkReleasePins } from './check-release-pins.ts';
import { collectPinFiles } from './collect-pin-files.ts';
import { parsePinTable } from './parse-pin-table.ts';
import { releaseRegistry } from './release-registry.ts';

// a copy of every file the registry's pins read in this checkout, with its committed pin table
async function setupTest() {
  const root = await mkdtemp(join(tmpdir(), 'check-release-pins-'));

  onTestFinished(() => rm(root, { recursive: true, force: true }));

  const checkout = join(import.meta.dir, '..', '..');
  const paths = [...new Set(releaseRegistry.flatMap((record) => collectPinFiles(record)))];

  await Promise.all(
    paths.map(async (path) => {
      await mkdir(dirname(join(root, path)), { recursive: true });
      await copyFile(join(checkout, path), join(root, path));
    }),
  );

  return {
    root,
    printOut: mock<(text: string) => void>(),
    printErr: mock<(text: string) => void>(),
  };
}

test('it passes when every pin matches the table', async () => {
  const ctx = await setupTest();
  const status = await checkReleasePins({ ...ctx, args: [] });

  expect(status).toBe(0);

  expect(ctx.printOut.mock.calls).toStrictEqual([
    ['check-release-pins: every pin matches scripts/release/release-pins.json\n'],
  ]);

  expect(ctx.printErr.mock.calls).toStrictEqual([]);
});

test('it fails with each mismatch and the way to rewrite the table', async () => {
  const ctx = await setupTest();

  const path = join(ctx.root, 'infra/Pulumi.prod.yaml');

  const stack = await readFile(path, 'utf8');

  const lines = stack.split('\n');
  const index = lines.findIndex((line) => / +image: ghcr\.io\/zgeoff\/nixie:/u.test(line));
  const pinned = /nixie:(?<version>[0-9.]+)@/u.exec(lines[index] ?? '')?.groups?.['version'] ?? '';

  await writeFile(path, stack.replace(`nixie:${pinned}@`, 'nixie:99.0.0@'));

  const status = await checkReleasePins({ ...ctx, args: [] });

  expect(status).toBe(1);
  expect(ctx.printOut.mock.calls).toStrictEqual([]);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    [
      `check-release-pins: nixie: infra/Pulumi.prod.yaml:${index + 1} holds 99.0.0 for version, but scripts/release/release-pins.json holds ${pinned}\ncheck-release-pins: a bump writes both; after a pin edit by hand, run bun scripts/release/check-release-pins.ts --write\n`,
    ],
  ]);
});

test('it rewrites the table from the pins with --write, so the check then passes', async () => {
  const ctx = await setupTest();

  const path = join(ctx.root, 'infra/Pulumi.prod.yaml');

  const stack = await readFile(path, 'utf8');

  await writeFile(path, stack.replace(/nixie:[0-9.]+@/u, 'nixie:99.0.0@'));

  const written = await checkReleasePins({ ...ctx, args: ['--write'] });
  const checked = await checkReleasePins({ ...ctx, args: [] });
  const text = await readFile(join(ctx.root, 'scripts/release/release-pins.json'), 'utf8');

  expect(written).toBe(0);
  expect(checked).toBe(0);
  expect(parsePinTable(text)).toMatchObject({ nixie: { version: '99.0.0' } });
});

test('it refuses to write a table when a pin line is missing', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.root, 'infra/Pulumi.prod.yaml'), 'nixie: {}\n');

  const status = await checkReleasePins({ ...ctx, args: ['--write'] });

  expect(status).toBe(1);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    [
      `${String.raw`check-release-pins: infra/Pulumi.prod.yaml has 0 lines that match '^ +image: ghcr\.io\/zgeoff\/nixie:(?<version>\d+\.\d+\.\d+)@(?<digest>sha256:[0-9a-f]{64})$', want 1`}\n`,
    ],
  ]);
});

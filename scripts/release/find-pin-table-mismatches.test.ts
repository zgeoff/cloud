import { expect, test } from 'bun:test';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { collectPinFiles } from './collect-pin-files.ts';
import { findPinTableMismatches } from './find-pin-table-mismatches.ts';
import { parsePinTable } from './parse-pin-table.ts';
import { releaseRegistry } from './release-registry.ts';

async function setupTest() {
  const root = join(import.meta.dir, '..', '..');
  const paths = [...new Set(releaseRegistry.flatMap((record) => collectPinFiles(record)))];

  const contents = await Promise.all(paths.map((path) => readFile(join(root, path), 'utf8')));

  return {
    files: Object.fromEntries(paths.map((path, index) => [path, contents[index] ?? ''])),
  };
}

test('it finds no mismatch between the checkout and its committed table', async () => {
  const ctx = await setupTest();

  expect(findPinTableMismatches(ctx.files)).toStrictEqual([]);
});

test('it reports a pin line that holds another version than the table', async () => {
  const ctx = await setupTest();

  const dockerfile = ctx.files['images/agent/Dockerfile'] ?? '';
  const table = parsePinTable(ctx.files['scripts/release/release-pins.json'] ?? '');

  if (table instanceof Error) {
    throw table;
  }

  const pinned = table['auto-mode']?.['version'] ?? '';
  const line = dockerfile.split('\n').indexOf(`ARG AUTO_MODE_VERSION=${pinned}`) + 1;

  expect(
    findPinTableMismatches({
      ...ctx.files,
      'images/agent/Dockerfile': dockerfile.replace(
        `ARG AUTO_MODE_VERSION=${pinned}\n`,
        'ARG AUTO_MODE_VERSION=99.0.0\n',
      ),
    }),
  ).toStrictEqual([
    `auto-mode: images/agent/Dockerfile:${line} holds 99.0.0 for version, but scripts/release/release-pins.json holds ${pinned}`,
  ]);
});

test('it reports a pin that the table lacks', async () => {
  const ctx = await setupTest();

  const table = parsePinTable(ctx.files['scripts/release/release-pins.json'] ?? '');

  if (table instanceof Error) {
    throw table;
  }

  const { 'nixie-web': _, ...rest } = table;

  expect(
    findPinTableMismatches({
      ...ctx.files,
      'scripts/release/release-pins.json': JSON.stringify(rest),
    }),
  ).toStrictEqual(['scripts/release/release-pins.json lacks nixie-web']);
});

test('it reports an entry that no registry record pins', async () => {
  const ctx = await setupTest();

  const table = parsePinTable(ctx.files['scripts/release/release-pins.json'] ?? '');

  if (table instanceof Error) {
    throw table;
  }

  expect(
    findPinTableMismatches({
      ...ctx.files,
      'scripts/release/release-pins.json': JSON.stringify({
        ...table,
        retired: { version: '1.0.0' },
      }),
    }),
  ).toStrictEqual([
    'scripts/release/release-pins.json holds retired, which no registry record pins',
  ]);
});

test('it reports a __proto__ entry as one that no registry record pins', async () => {
  const ctx = await setupTest();

  const text = ctx.files['scripts/release/release-pins.json'] ?? '';

  expect(
    findPinTableMismatches({
      ...ctx.files,
      'scripts/release/release-pins.json': text.replace(
        /^\{/u,
        '{"__proto__":{"version":"1.0.0"},',
      ),
    }),
  ).toStrictEqual([
    'scripts/release/release-pins.json holds __proto__, which no registry record pins',
  ]);
});

test('it reports a missing table', async () => {
  const ctx = await setupTest();

  const { 'scripts/release/release-pins.json': _, ...files } = ctx.files;

  expect(findPinTableMismatches(files)).toStrictEqual([
    'scripts/release/release-pins.json is missing',
  ]);
});

test('it reports a table that holds no JSON object', async () => {
  const ctx = await setupTest();

  expect(
    findPinTableMismatches({ ...ctx.files, 'scripts/release/release-pins.json': '[]\n' }),
  ).toStrictEqual(['scripts/release/release-pins.json holds no JSON object']);
});

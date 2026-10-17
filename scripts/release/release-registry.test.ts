import { expect, test } from 'bun:test';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { findPinMatch } from './find-pin-match.ts';
import { releaseRegistry } from './release-registry.ts';

test('it matches each pin line to exactly one line of the checkout', async () => {
  const root = join(import.meta.dir, '..', '..');
  const pinLines = releaseRegistry.flatMap((record) => record.pins.flatMap((pin) => pin.lines));

  const assetLines = pinLines.flatMap((line) =>
    Object.values(line.parts).flatMap((part) =>
      part.kind === 'sum' && typeof part.asset !== 'string' ? [part.asset] : [],
    ),
  );

  const lines = [...pinLines, ...assetLines];
  const paths = [...new Set(lines.map((line) => line.file))];

  const contents = await Promise.all(paths.map((path) => readFile(join(root, path), 'utf8')));

  const files = Object.fromEntries(paths.map((path, index) => [path, contents[index] ?? '']));

  const failures = lines.flatMap((line) => {
    const match = findPinMatch(files, line);

    return match instanceof Error ? [match.message] : [];
  });

  expect(failures).toStrictEqual([]);
});

test('it gives each record its own name', () => {
  const names = releaseRegistry.map((record) => record.name);

  expect([...new Set(names)]).toStrictEqual(names);
});

test('it gives each pin its own id', () => {
  const ids = releaseRegistry.flatMap((record) => record.pins.map((pin) => pin.id));

  expect([...new Set(ids)]).toStrictEqual(ids);
});

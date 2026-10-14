import { expect, test } from 'bun:test';
import { readFile } from 'node:fs/promises';
import { exposure, topology } from './index.ts';

test('it exports the constants file as written', async () => {
  const text = await readFile(new URL('constants.json', import.meta.url), 'utf8');

  const written: unknown = JSON.parse(text);

  expect(written).toStrictEqual(topology);
});

test('it exports the exposure registry as written', async () => {
  const text = await readFile(new URL('exposure.json', import.meta.url), 'utf8');

  const written: unknown = JSON.parse(text);

  expect(written).toStrictEqual(exposure);
});

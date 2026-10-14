import { expect, test } from 'bun:test';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { readHostScript } from './read-host-script.ts';

test('it reads a script from scripts/host/ whole', async () => {
  const expected = await readFile(join(import.meta.dir, 'host', 'mint-atc-imp-token.sh'));
  const script = await readHostScript('mint-atc-imp-token.sh');

  expect(script).toStrictEqual(Buffer.from(expected));
});

test('it rejects a script that does not exist', () => {
  expect(readHostScript('no-such-script.sh')).rejects.toMatchObject({ code: 'ENOENT' });
});

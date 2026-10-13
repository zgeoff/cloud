import { expect, test } from 'bun:test';
import { join } from 'node:path';
import { entryPath } from './entry-path.ts';

test('it names the module Workers loads', () => {
  expect(entryPath).toBe(join(import.meta.dir, 'index.ts'));
});

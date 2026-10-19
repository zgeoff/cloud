import { Database } from 'bun:sqlite';
import { expect, onTestFinished, test } from 'bun:test';
import { writeFile } from 'node:fs/promises';
import { isStorageFullError } from './is-storage-full-error.ts';

test('it recognises the error of a write to a full device', () => {
  expect(writeFile('/dev/full', 'bytes')).rejects.toSatisfy((thrown: unknown) =>
    isStorageFullError(thrown),
  );
});

test('it recognises the error of an insert into a full SQLite database', () => {
  const db = new Database(':memory:');

  onTestFinished(() => {
    db.close();
  });

  db.run('CREATE TABLE notes (body TEXT)');
  db.run('PRAGMA max_page_count = 2');

  const insert = db.query('INSERT INTO notes VALUES (?1)');

  expect(() => insert.run('n'.repeat(20_000))).toThrow(
    expect.toSatisfy((thrown: unknown) => isStorageFullError(thrown)),
  );
});

test('it does not take a missing directory for a full volume', () => {
  expect(writeFile('/nonexistent-dir-7f3a/file', 'bytes')).rejects.toSatisfy(
    (thrown: unknown) => !isStorageFullError(thrown),
  );
});

test.each([
  ['a plain error', new Error('no space left on device')],
  ['a string', 'ENOSPC'],
  ['an object with the code but no Error', { code: 'ENOSPC' }],
  ['undefined', undefined],
])('it does not take %s for a full volume', (_name, error) => {
  expect(isStorageFullError(error)).toBeFalse();
});

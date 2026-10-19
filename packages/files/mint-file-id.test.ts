import { expect, test } from 'bun:test';
import { mintFileID } from './mint-file-id.ts';

test('it mints 22 letters and digits', () => {
  expect(mintFileID()).toMatch(/^[A-Za-z\d]{22}$/u);
});

test('it mints a different id each time', () => {
  const ids = Array.from({ length: 1000 }, () => mintFileID());

  expect(new Set(ids).size).toBe(1000);
});

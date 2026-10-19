import { expect, test } from 'bun:test';
import { createHash } from 'node:crypto';
import { findTokenRole } from './find-token-role.ts';

test('it finds the owner role for the owner token', () => {
  const hashes = {
    agent: createHash('sha256').update('agent-secret-4f1c').digest('hex'),
    owner: createHash('sha256').update('owner-secret-9a7e').digest('hex'),
  };

  expect(findTokenRole('Bearer owner-secret-9a7e', hashes)).toBe('owner');
});

test('it finds the agent role for the agent token', () => {
  const hashes = {
    agent: createHash('sha256').update('agent-secret-4f1c').digest('hex'),
    owner: createHash('sha256').update('owner-secret-9a7e').digest('hex'),
  };

  expect(findTokenRole('Bearer agent-secret-4f1c', hashes)).toBe('agent');
});

test.each([
  ['no header', null],
  ['a wrong token', 'Bearer agent-secret-0000'],
  ['the token without its scheme', 'owner-secret-9a7e'],
  ['another scheme', 'Basic owner-secret-9a7e'],
  ['an empty bearer token', 'Bearer '],
  [
    'the hash in place of the token',
    'Bearer 845b5a8047a7e15ae10d77148eeb4f9759b3a3bb112d97064e61a02f0be6c5db',
  ],
])('it finds no role for %s', (_label, authorization) => {
  const hashes = {
    agent: createHash('sha256').update('agent-secret-4f1c').digest('hex'),
    owner: createHash('sha256').update('owner-secret-9a7e').digest('hex'),
  };

  expect(findTokenRole(authorization, hashes)).toBeUndefined();
});

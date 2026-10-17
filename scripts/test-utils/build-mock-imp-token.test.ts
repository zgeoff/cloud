import { expect, test } from 'bun:test';
import { buildMockImpToken } from './build-mock-imp-token.ts';

test('it builds a default imp token', () => {
  expect(buildMockImpToken()).toStrictEqual({
    name: 'atc-cloud',
    scope: 'manage',
    imps: ['harness-*'],
    sshKeys: [],
    grantable: [
      'claude-setup-token',
      'github-imp-agents',
      'glm',
      'linear-imp-agents',
      'op-connect',
    ],
    createdAt: '2026-10-07T12:00:00.000Z',
  });
});

test('it applies overrides on top of the defaults', () => {
  expect(buildMockImpToken({ scope: 'read', grantable: [] })).toStrictEqual({
    name: 'atc-cloud',
    scope: 'read',
    imps: ['harness-*'],
    sshKeys: [],
    grantable: [],
    createdAt: '2026-10-07T12:00:00.000Z',
  });
});

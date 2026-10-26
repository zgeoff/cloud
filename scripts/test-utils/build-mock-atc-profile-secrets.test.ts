import { expect, test } from 'bun:test';
import { buildMockATCProfileSecrets } from './build-mock-atc-profile-secrets.ts';

test('it builds the four secrets that the daemon’s auth profiles name', () => {
  expect(buildMockATCProfileSecrets()).toStrictEqual([
    {
      name: 'claude-setup-token',
      kind: 'custom',
      rules: [{ host: 'api.anthropic.com', header: 'authorization', scheme: 'bearer' }],
      imps: [],
      createdAt: '2026-10-07T12:00:00.000Z',
    },
    {
      name: 'github-imp-agents',
      kind: 'github',
      rules: [
        { host: 'github.com', header: 'authorization', scheme: 'basic' },
        { host: 'api.github.com', header: 'authorization', scheme: 'bearer' },
      ],
      imps: [],
      createdAt: '2026-10-07T12:00:00.000Z',
    },
    {
      name: 'linear-imp-agents',
      kind: 'custom',
      rules: [{ host: 'mcp.linear.app', header: 'authorization', scheme: 'bearer' }],
      imps: [],
      createdAt: '2026-10-07T12:00:00.000Z',
    },
    {
      name: 'op-connect',
      kind: 'custom',
      rules: [{ host: 'op-connect.imp.internal', header: 'authorization', scheme: 'bearer' }],
      imps: [],
      createdAt: '2026-10-07T12:00:00.000Z',
    },
  ]);
});

test('it builds fresh secrets on each call, so one test’s changes never reach another', () => {
  const first = buildMockATCProfileSecrets();

  first.pop();

  expect(buildMockATCProfileSecrets()).toHaveLength(4);
});

import { expect, test } from 'bun:test';
import { buildMockImpSecret } from './build-mock-imp-secret.ts';

test('it builds a default imp secret', () => {
  expect(buildMockImpSecret()).toStrictEqual({
    name: 'glm',
    kind: 'static',
    rules: [{ host: 'api.z.ai', header: 'authorization', scheme: 'bearer' }],
    env: [],
    imps: [],
    createdAt: '2026-10-07T12:00:00.000Z',
  });
});

test('it applies overrides on top of the defaults', () => {
  expect(buildMockImpSecret({ rules: [], imps: ['harness-a'] })).toStrictEqual({
    name: 'glm',
    kind: 'static',
    rules: [],
    env: [],
    imps: ['harness-a'],
    createdAt: '2026-10-07T12:00:00.000Z',
  });
});

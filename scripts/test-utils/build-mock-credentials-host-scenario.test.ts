import { expect, test } from 'bun:test';
import { buildMockCredentialsHostScenario } from './build-mock-credentials-host-scenario.ts';

test('it builds a default credentials host scenario', () => {
  expect(buildMockCredentialsHostScenario()).toStrictEqual({
    host: 'geoffcloud',
    dir: '/var/lib/atc-daemon-secrets',
    impdPort: '7070',
    info: { version: '0.27.0', features: { grantableTokens: true } },
    secrets: [
      {
        name: 'glm',
        kind: 'custom',
        rules: [{ host: 'api.z.ai', header: 'authorization', scheme: 'bearer' }],
        imps: [],
        createdAt: '2026-10-07T12:00:00.000Z',
      },
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
    ],
    tokens: [
      {
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
      },
    ],
    files: {
      'gateway-token': { content: 'fixture-bearer\n', mode: '400' },
      'imp-token': { content: 'imp_fixture_saved\n', mode: '400' },
    },
  });
});

test('it applies overrides on top of the defaults', () => {
  expect(
    buildMockCredentialsHostScenario({ secrets: [], files: {}, unreachable: true }),
  ).toMatchObject({
    host: 'geoffcloud',
    secrets: [],
    files: {},
    unreachable: true,
  });
});

test('it builds fresh state on each call, so one test’s changes never reach another', () => {
  const first = buildMockCredentialsHostScenario();
  const second = buildMockCredentialsHostScenario();

  first.secrets.push({ name: 'extra' });

  first.files['extra'] = { content: '', mode: '600' };

  expect(second.secrets).toHaveLength(5);
  expect(Object.keys(second.files)).toStrictEqual(['gateway-token', 'imp-token']);
});

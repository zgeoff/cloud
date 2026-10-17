// An impd token as `impz token ls --json` prints it, after imp 1.0.0's TokenSchema
// (packages/api/src/token-schema.ts): the atc-cloud token that install-atc-gateway-credentials
// mints, by default. The script compares its values, so each is fixed, grantable as a set.
export interface MockImpToken {
  readonly name: string;
  readonly scope: string;
  readonly imps: readonly string[];
  readonly sshKeys: readonly string[];
  readonly grantable: readonly string[];
  readonly createdAt: string;
}

export function buildMockImpToken(overrides: Partial<MockImpToken> = {}): MockImpToken {
  return {
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
    ...overrides,
  };
}

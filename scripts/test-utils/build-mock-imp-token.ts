export interface MockImpToken {
  readonly name: string;
  readonly scope: string;
  readonly imps: readonly string[];
  readonly sshKeys: readonly string[];
  readonly grantable: readonly string[];
  readonly createdAt: string;
}

export function buildMockImpToken(overrides: Partial<MockImpToken> = {}): MockImpToken {
  // the values are fixed, grantable as a set, since the script under test compares them
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

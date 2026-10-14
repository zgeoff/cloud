// An impd token as `imp token ls --json` prints it, after imp 1.0.0's TokenSchema
// (packages/api/src/token-schema.ts): the atc-cloud token that install-atc-gateway-credentials
// mints, by default. Its values are fixed: the script compares them, so none is arbitrary.
export interface MockImpToken {
  name: string;
  scope: string;
  imps: string[];
  sshKeys: string[];
  grantable: string[];
  createdAt: string;
}

export function buildMockImpToken(overrides: Partial<MockImpToken> = {}): MockImpToken {
  return {
    name: 'atc-cloud',
    scope: 'manage',
    imps: ['harness-*'],
    sshKeys: [],
    grantable: ['glm'],
    createdAt: '2026-10-07T12:00:00.000Z',
    ...overrides,
  };
}

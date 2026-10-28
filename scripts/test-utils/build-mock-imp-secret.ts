export interface MockImpSecret {
  readonly name: string;
  readonly kind: string;
  readonly rules: readonly {
    readonly host: string;
    readonly header: string;
    readonly scheme: string;
  }[];
  readonly env: readonly string[];
  readonly imps: readonly string[];
  readonly createdAt: string;
}

export function buildMockImpSecret(overrides: Partial<MockImpSecret> = {}): MockImpSecret {
  // the values are fixed, since the script under test compares them
  return {
    name: 'glm',
    kind: 'static',
    rules: [{ host: 'api.z.ai', header: 'authorization', scheme: 'bearer' }],
    env: [],
    imps: [],
    createdAt: '2026-10-07T12:00:00.000Z',
    ...overrides,
  };
}

// An impd secret as `impz secret ls --json` prints it, after imp 1.0.0's SecretSchema
// (packages/api/src/secret-schema.ts): the glm secret that install-atc-gateway-credentials adds,
// by default. Its values are fixed: the script compares them, so none is arbitrary.
export interface MockImpSecret {
  readonly name: string;
  readonly kind: string;
  readonly rules: readonly {
    readonly host: string;
    readonly header: string;
    readonly scheme: string;
  }[];
  readonly imps: readonly string[];
  readonly createdAt: string;
}

export function buildMockImpSecret(overrides: Partial<MockImpSecret> = {}): MockImpSecret {
  return {
    name: 'glm',
    kind: 'custom',
    rules: [{ host: 'api.z.ai', header: 'authorization', scheme: 'bearer' }],
    imps: [],
    createdAt: '2026-10-07T12:00:00.000Z',
    ...overrides,
  };
}

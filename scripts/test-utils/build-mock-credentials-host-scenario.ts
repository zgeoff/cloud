import { buildMockATCProfileSecrets } from './build-mock-atc-profile-secrets.ts';
import { buildMockImpSecret } from './build-mock-imp-secret.ts';
import { buildMockImpToken } from './build-mock-imp-token.ts';
import type { StubCredentialsHostScenario } from './build-stub-credentials-host.ts';

export function buildMockCredentialsHostScenario(
  overrides: Partial<StubCredentialsHostScenario> = {},
): StubCredentialsHostScenario {
  return {
    host: 'geoffcloud',
    directory: '/var/lib/atc-daemon-secrets',
    impdPort: '7070',
    info: { version: '0.27.0', features: { grantableTokens: true } },
    secrets: [{ ...buildMockImpSecret() }, ...buildMockATCProfileSecrets()],
    tokens: [{ ...buildMockImpToken() }],
    files: {
      'gateway-token': { content: 'fixture-bearer\n', mode: '400' },
      'imp-token': { content: 'imp_fixture_saved\n', mode: '400' },
    },
    ...overrides,
  };
}

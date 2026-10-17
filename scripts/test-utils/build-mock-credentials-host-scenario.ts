import { buildMockImpSecret } from './build-mock-imp-secret.ts';
import { buildMockImpToken } from './build-mock-imp-token.ts';
import type { StubCredentialsHostScenario } from './build-stub-credentials-host.ts';

// The host install-atc-gateway-credentials finds when its last run finished: impd has glm and
// atc-cloud, and the secrets directory at the script's default path holds both files
export function buildMockCredentialsHostScenario(
  overrides: Partial<StubCredentialsHostScenario> = {},
): StubCredentialsHostScenario {
  return {
    host: 'root@geoffcloud',
    dir: '/var/lib/atc-daemon-secrets',
    impdPort: '7070',
    info: { version: '0.27.0', features: { grantableTokens: true } },
    secrets: [{ ...buildMockImpSecret() }],
    tokens: [{ ...buildMockImpToken() }],
    files: {
      'gateway-token': { content: 'fixture-bearer\n', mode: '400' },
      'imp-token': { content: 'imp_fixture_saved\n', mode: '400' },
    },
    ...overrides,
  };
}

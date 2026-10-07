import type { ATCDaemonEndpoint } from '../build-alert-rules.ts';

// infra's outputs are pinned as literals, so every default is fixed
export function buildMockATCDaemonEndpoint(
  overrides: Partial<ATCDaemonEndpoint> = {},
): ATCDaemonEndpoint {
  return {
    name: 'geoffcloud',
    address: '100.64.0.1:8415',
    alertSeverity: 'critical',
    ...overrides,
  };
}

import { buildMockImpSecret } from './build-mock-imp-secret.ts';

export function buildMockATCProfileSecrets(): Record<string, unknown>[] {
  // the names are fixed, since the installer's preflight and impd's mint look them up by name
  return [
    {
      ...buildMockImpSecret({
        name: 'claude-setup-token',
        rules: [{ host: 'api.anthropic.com', header: 'authorization', scheme: 'bearer' }],
      }),
    },
    {
      ...buildMockImpSecret({
        name: 'github-imp-agents',
        kind: 'github',
        rules: [
          { host: 'github.com', header: 'authorization', scheme: 'basic' },
          { host: 'api.github.com', header: 'authorization', scheme: 'bearer' },
        ],
      }),
    },
    {
      ...buildMockImpSecret({
        name: 'linear-imp-agents',
        rules: [{ host: 'mcp.linear.app', header: 'authorization', scheme: 'bearer' }],
      }),
    },
    {
      ...buildMockImpSecret({
        name: 'op-connect',
        rules: [{ host: 'op-connect.imp.internal', header: 'authorization', scheme: 'bearer' }],
      }),
    },
  ];
}

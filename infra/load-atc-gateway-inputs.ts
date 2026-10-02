import { Config, secret } from '@pulumi/pulumi';
import type { ATCGatewayBackupSecrets, ATCGatewayConfig, ATCGatewayInputs } from './atc-gateway.ts';

// The atc gateway's inputs, or nothing while the stack config leaves atcGateway
// unset; setting it is an approval step in docs/runbooks/atc-gateway-operator-checklist.md.
// Secrets come from .env's op:// references: ATC_GATEWAY_DAEMON_TOKENS (a JSON
// object, env var → token) and the ATC_GATEWAY_RESTIC_* and ATC_GATEWAY_R2_* values.
export function loadATCGatewayInputs(): { readonly atcGateway?: ATCGatewayInputs } {
  const config = new Config().getObject<ATCGatewayConfig>('atcGateway');

  if (config === undefined) {
    return {};
  }

  const tokens = parseTokens(process.env['ATC_GATEWAY_DAEMON_TOKENS'] ?? '{}');
  const backup = findBackupSecrets();

  return {
    atcGateway: {
      config,
      secrets: {
        daemonTokens: Object.fromEntries(
          Object.entries(tokens).map(([name, value]) => [name, secret(value)]),
        ),
        ...(backup === undefined ? {} : { backup }),
      },
    },
  };
}

function parseTokens(raw: string): Record<string, string> {
  const parsed: unknown = JSON.parse(raw);

  if (!isStringRecord(parsed)) {
    throw new Error('ATC_GATEWAY_DAEMON_TOKENS must be a JSON object of env var → token');
  }

  return parsed;
}

function isStringRecord(value: unknown): value is Record<string, string> {
  return (
    typeof value === 'object' &&
    value !== null &&
    !Array.isArray(value) &&
    Object.values(value).every((item) => typeof item === 'string')
  );
}

const backupVariables = {
  repository: 'ATC_GATEWAY_RESTIC_REPOSITORY',
  password: 'ATC_GATEWAY_RESTIC_PASSWORD',
  accessKeyID: 'ATC_GATEWAY_R2_ACCESS_KEY_ID',
  secretAccessKey: 'ATC_GATEWAY_R2_SECRET_ACCESS_KEY',
} as const;

// all four set, or no backup
function findBackupSecrets(): ATCGatewayBackupSecrets | undefined {
  const values = Object.values(backupVariables).map((name) => process.env[name] ?? '');

  if (values.includes('')) {
    return undefined;
  }

  const [repository = '', password = '', accessKeyID = '', secretAccessKey = ''] = values;

  return {
    repository: secret(repository),
    password: secret(password),
    accessKeyID: secret(accessKeyID),
    secretAccessKey: secret(secretAccessKey),
  };
}

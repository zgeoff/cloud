import { Config, secret } from '@pulumi/pulumi';
import type { ATCGatewayBackupSecrets, ATCGatewayConfig, ATCGatewayInputs } from './atc-gateway.ts';
import { requireATCGatewayInputs } from './require-atc-gateway-inputs.ts';

// The atc gateway's inputs, or nothing while the stack config leaves atcGateway
// unset; setting it is an approval step in docs/runbooks/atc-gateway-operator-checklist.md.
// Secrets come from .env's op:// references: ATC_GATEWAY_TOKEN_GEOFFCLOUD (the
// daemon's bearer token) and the ATC_GATEWAY_RESTIC_* and ATC_GATEWAY_R2_* values.
export function loadATCGatewayInputs(): { readonly atcGateway?: ATCGatewayInputs } {
  const config = new Config().getObject<ATCGatewayConfig>('atcGateway');

  if (config === undefined) {
    return {};
  }

  const checked = requireATCGatewayInputs(config, process.env);
  const backup = findBackupSecrets();

  return {
    atcGateway: {
      config,
      daemon: { address: checked.daemonAddress, daemonID: checked.daemonID },
      secrets: {
        token: secret(checked.token),
        ...(backup === undefined ? {} : { backup }),
      },
    },
  };
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

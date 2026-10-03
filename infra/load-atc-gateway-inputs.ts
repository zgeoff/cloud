import { Config, secret } from '@pulumi/pulumi';
import type { ATCGatewayBackupSecrets, ATCGatewayConfig, ATCGatewayInputs } from './atc-gateway.ts';
import { findATCGatewayBackup } from './find-atc-gateway-backup.ts';
import { requireATCGatewayInputs } from './require-atc-gateway-inputs.ts';

// The atc gateway's inputs, or nothing while the stack config leaves atcGateway
// unset; setting it is an approval step in docs/runbooks/atc-gateway-operator-checklist.md.
// Secrets come from .env's op:// references: ATC_GATEWAY_TOKEN_GEOFFCLOUD (the
// daemon's bearer token) and the backup's ATC_GATEWAY_RESTIC_* and ATC_GATEWAY_R2_* values.
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

// all set, or no backup; findATCGatewayBackup throws on a partial set
function findBackupSecrets(): ATCGatewayBackupSecrets | undefined {
  const backup = findATCGatewayBackup(process.env);

  if (backup === undefined) {
    return undefined;
  }

  return {
    repository: secret(backup.repository),
    password: secret(backup.password),
    accessKeyID: secret(backup.accessKeyID),
    secretAccessKey: secret(backup.secretAccessKey),
  };
}

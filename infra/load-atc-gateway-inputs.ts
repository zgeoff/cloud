import { secret } from '@pulumi/pulumi';
import type { Config } from '@pulumi/pulumi';
import type { ATCGatewayBackupSecrets, ATCGatewayConfig, ATCGatewayInputs } from './atc-gateway.ts';
import { findATCGatewayBackup } from './find-atc-gateway-backup.ts';
import { requireATCGatewayInputs } from './require-atc-gateway-inputs.ts';

// the stack config methods this reads: Pulumi's Config, or a stand-in in a test
type ATCGatewayStackConfig = Pick<Config, 'getObject'>;

type Environment = Readonly<Record<string, string | undefined>>;

// The atc gateway's inputs, or nothing while the stack config leaves atcGateway
// unset; setting it is an approval step in docs/runbooks/atc-gateway-operator-checklist.md.
// Secrets come from .env's op:// references: ATC_GATEWAY_TOKEN_<NAME> for each daemon
// (its bearer token, such as ATC_GATEWAY_TOKEN_GEOFFCLOUD) and the backup's
// ATC_GATEWAY_RESTIC_* and ATC_GATEWAY_R2_* values.
export function loadATCGatewayInputs(
  stackConfig: ATCGatewayStackConfig,
  env: Environment,
): { readonly atcGateway?: ATCGatewayInputs } {
  const config = stackConfig.getObject<ATCGatewayConfig>('atcGateway');

  if (config === undefined) {
    return {};
  }

  const checked = requireATCGatewayInputs(config, env);
  const daemons = Object.entries(checked.daemons);
  const backup = findBackupSecrets(env);

  return {
    atcGateway: {
      config,
      daemons: Object.fromEntries(
        daemons.map(([name, daemon]) => [
          name,
          {
            address: daemon.address,
            daemonID: daemon.daemonID,
            alertSeverity: daemon.alertSeverity,
          },
        ]),
      ),
      defaultDaemon: checked.defaultDaemon,
      secrets: {
        tokens: Object.fromEntries(daemons.map(([name, daemon]) => [name, secret(daemon.token)])),
        ...(backup === undefined ? {} : { backup }),
      },
    },
  };
}

// all set, or no backup; findATCGatewayBackup throws on a partial set
function findBackupSecrets(env: Environment): ATCGatewayBackupSecrets | undefined {
  const backup = findATCGatewayBackup(env);

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

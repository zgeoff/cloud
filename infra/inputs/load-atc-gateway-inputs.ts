import { secret } from '@pulumi/pulumi';
import { findResticBackup } from './find-restic-backup.ts';
import { requireATCGatewayInputs } from './require-atc-gateway-inputs.ts';
import type {
  ATCGatewayBackupSecrets,
  ATCGatewayInputs,
  Environment,
  StackConfig,
} from './types.ts';

// The gateway's inputs, or nothing while atcGateway is unset (setting it approves the deploy).
// Secrets come from .env's op:// references: ATC_GATEWAY_TOKEN_<NAME> per daemon plus the
// backup's ATC_GATEWAY_RESTIC_* and ATC_GATEWAY_R2_* values.
export function loadATCGatewayInputs(
  stackConfig: Pick<StackConfig, 'getObject'>,
  env: Environment,
): { readonly atcGateway?: ATCGatewayInputs } {
  // unknown until the schema checks it
  const raw = stackConfig.getObject<unknown>('atcGateway');

  if (raw === undefined) {
    return {};
  }

  const checked = requireATCGatewayInputs(raw, env);
  const backup = findBackupSecrets(env);

  return {
    atcGateway: {
      config: checked.config,
      secrets: {
        tokens: Object.fromEntries(
          Object.entries(checked.tokens).map(([name, token]) => [name, secret(token)]),
        ),
        ...(backup === undefined ? {} : { backup }),
      },
    },
  };
}

// all set, or no backup; findResticBackup throws on a partial set
function findBackupSecrets(env: Environment): ATCGatewayBackupSecrets | undefined {
  const backup = findResticBackup(env, {
    prefix: 'ATC_GATEWAY',
    label: "the atc gateway's backup",
    path: 'atc-gateway',
  });

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

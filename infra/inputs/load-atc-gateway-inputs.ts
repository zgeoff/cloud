import { secret } from '@pulumi/pulumi';
import type { Output } from '@pulumi/pulumi';
import { findResticBackup } from './find-restic-backup.ts';
import { loadATCGatewayServiceTokens } from './load-atc-gateway-service-tokens.ts';
import type { ATCGatewayServiceTokenOptions } from './load-atc-gateway-service-tokens.ts';
import { requireATCGatewayInputs } from './require-atc-gateway-inputs.ts';
import { requireGHCRPullCredential } from './require-ghcr-pull-credential.ts';
import type {
  ATCGatewayBackupSecrets,
  ATCGatewayInputs,
  Environment,
  StackConfig,
} from './types.ts';

export function loadATCGatewayInputs(
  stackConfig: Pick<StackConfig, 'getObject' | 'getSecret'>,
  env: Environment,
  serviceTokenOptions?: ATCGatewayServiceTokenOptions,
): { readonly atcGateway?: ATCGatewayInputs } {
  const raw = stackConfig.getObject('atcGateway');

  if (raw === undefined) {
    return {};
  }

  const checked = requireATCGatewayInputs(raw, env);
  const pull = requireGHCRPullCredential(env);
  const backup = findBackupSecrets(env);
  const ownerEmail = requireOwnerEmail(stackConfig);
  const serviceTokens = loadATCGatewayServiceTokens(env, checked.config.image, serviceTokenOptions);

  return {
    atcGateway: {
      config: checked.config,
      secrets: {
        pullCredential: { username: pull.username, token: secret(pull.token) },
        tokens: Object.fromEntries(
          Object.entries(checked.tokens).map(([name, token]) => [name, secret(token)]),
        ),
        ...(backup === undefined ? {} : { backup }),
        ...(serviceTokens === undefined ? {} : { serviceTokens }),
        ownerEmail,
      },
    },
  };
}

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

function requireOwnerEmail(stackConfig: Pick<StackConfig, 'getSecret'>): Output<string> {
  const ownerEmail = stackConfig.getSecret('atcGatewayOwnerEmail');

  if (ownerEmail === undefined) {
    throw new Error(
      "atcGatewayOwnerEmail is unset; the Access policy in front of the gateway's sign-in pages needs it: run `pulumi config set --secret atcGatewayOwnerEmail <owner address>` in infra/",
    );
  }

  return ownerEmail;
}

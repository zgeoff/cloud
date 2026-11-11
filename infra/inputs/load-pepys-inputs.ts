import { secret } from '@pulumi/pulumi';
import type { Output } from '@pulumi/pulumi';
import { z } from 'zod';
import { findVariable } from './find-variable.ts';
import { parseStackObject } from './parse-stack-object.ts';
import { requireGeoffCloudHostname } from './require-geoff-cloud-hostname.ts';
import { requireGHCRPullCredential } from './require-ghcr-pull-credential.ts';
import { requirePinnedImage } from './require-pinned-image.ts';
import { requireVariable } from './require-variable.ts';
import type { Environment, PepysBackupInputs, PepysInputs, StackConfig } from './types.ts';

// a missing field reaches its own check below, which names what the field must hold
const pepysConfigSchema = z.object({
  image: z.string().optional(),
  webhookHostname: z.string().optional(),
  impIdentityAudience: z.string().min(1).optional(),
});

// setting stack config "pepys" approves the deploy; the PEPYS_BACKUP_* and PEPYS_R2_* variables
// add the backup
export function loadPepysInputs(
  stackConfig: Pick<StackConfig, 'getObject'>,
  env: Environment,
  ingestSecretVariables: readonly string[],
): { readonly pepys?: PepysInputs } {
  const raw = stackConfig.getObject('pepys');

  if (raw === undefined) {
    return {};
  }

  const config = parseStackObject('pepys', raw, pepysConfigSchema);

  requirePinnedImage('pepys.image', config.image);
  requireGeoffCloudHostname('pepys.webhookHostname', config.webhookHostname);

  const pull = requireGHCRPullCredential(env);
  const backup = findBackup(env);

  requireGarageKey(env);

  return {
    pepys: {
      config: {
        image: config.image,
        webhookHostname: config.webhookHostname,
        ...(config.impIdentityAudience === undefined
          ? {}
          : { impIdentityAudience: config.impIdentityAudience }),
      },
      pullCredential: { username: pull.username, token: secret(pull.token) },
      secrets: {
        garageRPCSecret: requireSecret(env, 'PEPYS_GARAGE_RPC_SECRET'),
        garageAdminToken: requireSecret(env, 'PEPYS_GARAGE_ADMIN_TOKEN'),
        s2GarageAccessKeyID: requireSecret(env, 'PEPYS_S2_GARAGE_ACCESS_KEY_ID'),
        s2GarageSecretAccessKey: requireSecret(env, 'PEPYS_S2_GARAGE_SECRET_ACCESS_KEY'),
        s2AccessToken: requireSecret(env, 'PEPYS_S2_ACCESS_TOKEN'),
        ingest: Object.fromEntries(
          ingestSecretVariables.map((name) => [name, requireSecret(env, name)]),
        ),
      },
      ...(backup === undefined ? {} : { backup }),
    },
  };
}

const backupVariables = {
  garageAccessKeyID: 'PEPYS_BACKUP_GARAGE_ACCESS_KEY_ID',
  garageSecretAccessKey: 'PEPYS_BACKUP_GARAGE_SECRET_ACCESS_KEY',
  r2Endpoint: 'PEPYS_R2_ENDPOINT',
  r2Bucket: 'PEPYS_R2_BUCKET',
  r2AccessKeyID: 'PEPYS_R2_ACCESS_KEY_ID',
  r2SecretAccessKey: 'PEPYS_R2_SECRET_ACCESS_KEY',
} as const;

function findBackup(env: Environment): PepysBackupInputs | undefined {
  const names = Object.values(backupVariables);
  const set = names.filter((name) => findVariable(env, name) !== undefined);

  if (set.length === 0) {
    return undefined;
  }

  if (set.length < names.length) {
    const unset = names.filter((name) => !set.includes(name));

    throw new Error(
      `the pepys bucket backup needs every one of ${names.join(', ')}; unset: ${unset.join(', ')}`,
    );
  }

  const endpoint = requireSecret(env, backupVariables.r2Endpoint);

  if (!/^https:\/\/[^/]+$/u.test(env[backupVariables.r2Endpoint] ?? '')) {
    throw new Error(`${backupVariables.r2Endpoint} must be an https:// origin with no path`);
  }

  return {
    secrets: {
      garageAccessKeyID: requireSecret(env, backupVariables.garageAccessKeyID),
      garageSecretAccessKey: requireSecret(env, backupVariables.garageSecretAccessKey),
      r2Endpoint: endpoint,
      r2Bucket: requireSecret(env, backupVariables.r2Bucket),
      r2AccessKeyID: requireSecret(env, backupVariables.r2AccessKeyID),
      r2SecretAccessKey: requireSecret(env, backupVariables.r2SecretAccessKey),
    },
  };
}

const need = 'pepys needs it while stack config "pepys" is set';

function requireSecret(env: Environment, name: string): Output<string> {
  return secret(requireVariable(env, name, need));
}

// Garage imports s2-lite's key at its first start and refuses a key in any other form
function requireGarageKey(env: Environment): void {
  const id = requireVariable(env, 'PEPYS_S2_GARAGE_ACCESS_KEY_ID', need);
  const key = requireVariable(env, 'PEPYS_S2_GARAGE_SECRET_ACCESS_KEY', need);

  if (!/^GK[\da-f]{24}$/u.test(id) || !/^[\da-f]{64}$/u.test(key)) {
    throw new Error(
      'PEPYS_S2_GARAGE_ACCESS_KEY_ID must be GK and 24 hex digits, and PEPYS_S2_GARAGE_SECRET_ACCESS_KEY 64 hex digits',
    );
  }
}

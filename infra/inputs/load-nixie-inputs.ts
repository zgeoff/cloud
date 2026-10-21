import { secret } from '@pulumi/pulumi';
import { z } from 'zod';
import { findResticBackup } from './find-restic-backup.ts';
import { parseStackObject } from './parse-stack-object.ts';
import { requireGeoffCloudHostname } from './require-geoff-cloud-hostname.ts';
import { requirePinnedImage } from './require-pinned-image.ts';
import { requireVariable } from './require-variable.ts';
import type {
  BackupImage,
  Environment,
  NixieBackupInputs,
  NixieInputs,
  StackConfig,
} from './types.ts';

// why each of nixie's secrets is required, for requireVariable's error
const nixieNeed = 'nixie needs it while stack config "nixie" is set';

// a missing field reaches its own check below, which names what the field must hold
const nixieConfigSchema = z.object({
  image: z.string().optional(),
  webImage: z.string().optional(),
  hostname: z.string().optional(),
  backupImage: z.unknown().optional(),
});

// nixie's inputs, or nothing while nixie is unset (setting it approves the deploy). Secrets come
// from .env, plus Pulumi's CLOUDFLARE_API_TOKEN for DNS-01. NIXIE_RESTIC_* and NIXIE_R2_* add the
// backup, in the gateway's backup image and with the gateway's pull credential.
export function loadNixieInputs(
  stackConfig: Pick<StackConfig, 'getObject'>,
  env: Environment,
  backupImage: BackupImage | undefined,
): { readonly nixie?: NixieInputs } {
  const raw = stackConfig.getObject('nixie');

  if (raw === undefined) {
    return {};
  }

  const config = parseStackObject('nixie', raw, nixieConfigSchema);

  if (config.backupImage !== undefined) {
    throw new Error(
      'stack config "nixie.backupImage" is no longer read: nixie\'s backup runs in "atcGateway.backupImage", so remove it',
    );
  }

  requirePinnedImage('nixie.image', config.image);
  requirePinnedImage('nixie.webImage', config.webImage);

  // the DNS record and the certificate live in the geoff.cloud zone
  requireGeoffCloudHostname('nixie.hostname', config.hostname);

  const backup = findBackup(env, backupImage);

  return {
    nixie: {
      config: { image: config.image, webImage: config.webImage, hostname: config.hostname },
      secrets: {
        ageHostKey: secret(requireVariable(env, 'NIXIE_AGE_HOST_KEY', nixieNeed)),
        definitionsDeployKey: secret(
          requireVariable(env, 'NIXIE_DEFINITIONS_DEPLOY_KEY', nixieNeed),
        ),
        dnsToken: secret(requireVariable(env, 'CLOUDFLARE_API_TOKEN', nixieNeed)),
      },
      ...(backup === undefined ? {} : { backup }),
    },
  };
}

// all backup variables set, or no backup; findResticBackup throws on a partial set
function findBackup(
  env: Environment,
  backupImage: BackupImage | undefined,
): NixieBackupInputs | undefined {
  const backup = findResticBackup(env, { prefix: 'NIXIE', label: "nixie's backup", path: 'nixie' });

  if (backup === undefined) {
    return undefined;
  }

  if (backupImage === undefined) {
    throw new Error(
      'nixie\'s backup runs in stack config "atcGateway.backupImage", which is unset: set atcGateway, or unset the NIXIE backup variables',
    );
  }

  return {
    image: backupImage.reference,
    pullCredential: backupImage.pullCredential,
    secrets: {
      repository: secret(backup.repository),
      password: secret(backup.password),
      accessKeyID: secret(backup.accessKeyID),
      secretAccessKey: secret(backup.secretAccessKey),
    },
  };
}

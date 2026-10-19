import { secret } from '@pulumi/pulumi';
import { findResticBackup } from './find-restic-backup.ts';
import { requireGeoffCloudHostname } from './require-geoff-cloud-hostname.ts';
import { requirePinnedImage } from './require-pinned-image.ts';
import { requireVariable } from './require-variable.ts';
import type {
  BackupImage,
  Environment,
  NixieBackupInputs,
  NixieConfig,
  NixieInputs,
  StackConfig,
} from './types.ts';

// why each of nixie's secrets is required, for requireVariable's error
const nixieNeed = 'nixie needs it while stack config "nixie" is set';

// nixie's inputs, or nothing while nixie is unset (setting it approves the deploy). Secrets come
// from .env, plus Pulumi's CLOUDFLARE_API_TOKEN for DNS-01. NIXIE_RESTIC_* and NIXIE_R2_* add the
// backup, in the gateway's backup image and with the gateway's pull credential.
export function loadNixieInputs(
  stackConfig: Pick<StackConfig, 'getObject'>,
  env: Environment,
  backupImage: BackupImage | undefined,
): { readonly nixie?: NixieInputs } {
  const config = stackConfig.getObject<NixieConfig>('nixie');

  if (config === undefined) {
    return {};
  }

  if (Object.hasOwn(config, 'backupImage')) {
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

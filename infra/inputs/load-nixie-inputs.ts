import { secret } from '@pulumi/pulumi';
import { findResticBackup } from './find-restic-backup.ts';
import { pinnedImagePattern } from './pinned-image-pattern.ts';
import { requireVariable } from './require-variable.ts';
import type {
  Environment,
  NixieBackupInputs,
  NixieConfig,
  NixieInputs,
  StackConfig,
} from './types.ts';

// why each of nixie's secrets is required, for requireVariable's error
const nixieNeed = 'nixie needs it while stack config "nixie" is set';

// nixie's inputs, or nothing while nixie is unset (setting it approves the deploy). Secrets come
// from .env's op:// references, plus Pulumi's CLOUDFLARE_API_TOKEN for the certificate's DNS-01.
// NIXIE_RESTIC_* and NIXIE_R2_* add the backup, in the one backup image, atcGateway.backupImage.
export function loadNixieInputs(
  stackConfig: Pick<StackConfig, 'getObject'>,
  env: Environment,
  backupImage: string | undefined,
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

  requirePinnedImage('image', config.image);
  requirePinnedImage('webImage', config.webImage);
  requireHostname(config.hostname);

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
  backupImage: string | undefined,
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
    image: backupImage,
    secrets: {
      repository: secret(backup.repository),
      password: secret(backup.password),
      accessKeyID: secret(backup.accessKeyID),
      secretAccessKey: secret(backup.secretAccessKey),
    },
  };
}

function requirePinnedImage(key: string, image: string | undefined): asserts image is string {
  if (image === undefined || !pinnedImagePattern.test(image)) {
    throw new Error(`stack config "nixie.${key}" must name an image by tag and digest`);
  }
}

// the DNS record and the certificate live in the geoff.cloud zone
const hostnamePattern = /^(?:[a-z\d](?:[a-z\d-]*[a-z\d])?\.)+geoff\.cloud$/u;

function requireHostname(hostname: string | undefined): void {
  if (hostname === undefined || !hostnamePattern.test(hostname)) {
    throw new Error('stack config "nixie.hostname" must name a host under geoff.cloud');
  }
}

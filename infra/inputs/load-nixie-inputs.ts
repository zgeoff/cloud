import { secret } from '@pulumi/pulumi';
import { z } from 'zod';
import { findResticBackup } from './find-restic-backup.ts';
import { parseStackObject } from './parse-stack-object.ts';
import { requireGeoffCloudHostname } from './require-geoff-cloud-hostname.ts';
import { requirePinnedImage } from './require-pinned-image.ts';
import { requireVariable } from './require-variable.ts';
import type {
  Environment,
  GHCRPullCredential,
  NixieBackupInputs,
  NixieInputs,
  StackConfig,
} from './types.ts';

const nixieNeed = 'nixie needs it while stack config "nixie" is set';

// a missing field reaches its own check below, which names what the field must hold
const nixieConfigSchema = z.object({
  image: z.string().optional(),
  webImage: z.string().optional(),
  hostname: z.string().optional(),
  backupImage: z.string().optional(),
});

// setting stack config "nixie" approves the deploy; NIXIE_RESTIC_*, NIXIE_R2_* and
// NIXIE_KEY_RESTIC_PASSWORD add the backup, which runs nixie.backupImage
export function loadNixieInputs(
  stackConfig: Pick<StackConfig, 'getObject'>,
  env: Environment,
  pullCredential: GHCRPullCredential | undefined,
): { readonly nixie?: NixieInputs } {
  const raw = stackConfig.getObject('nixie');

  if (raw === undefined) {
    return {};
  }

  const config = parseStackObject('nixie', raw, nixieConfigSchema);

  requirePinnedImage('nixie.image', config.image);
  requirePinnedImage('nixie.webImage', config.webImage);

  // the DNS record and the certificate live in the geoff.cloud zone
  requireGeoffCloudHostname('nixie.hostname', config.hostname);

  const backup = findBackup(
    env,
    { image: config.image, backupImage: config.backupImage },
    pullCredential,
  );

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

interface NixieImages {
  readonly image: string;
  readonly backupImage: string | undefined;
}

function findBackup(
  env: Environment,
  images: NixieImages,
  pullCredential: GHCRPullCredential | undefined,
): NixieBackupInputs | undefined {
  const backup = findResticBackup(env, { prefix: 'NIXIE', label: "nixie's backup", path: 'nixie' });

  if (backup === undefined) {
    return undefined;
  }

  const image = requireReleaseBackupImage(images);

  if (pullCredential === undefined) {
    throw new Error(
      'nixie\'s backup pulls its image with the GHCR login of stack config "atcGateway", which is unset: set atcGateway, or unset the NIXIE backup variables',
    );
  }

  return {
    image,
    pullCredential,
    secrets: {
      dataRepository: secret(backup.repository),
      dataPassword: secret(backup.password),

      // the data repo's bucket and R2 key, beside it under a path and a password of its own
      keyRepository: secret(`${backup.repository}-keys`),
      keyPassword: secret(
        requireVariable(env, 'NIXIE_KEY_RESTIC_PASSWORD', "nixie's backup needs it"),
      ),
      accessKeyID: secret(backup.accessKeyID),
      secretAccessKey: secret(backup.secretAccessKey),
    },
  };
}

const backupRepository = 'ghcr.io/zgeoff/nixie-backup';

// the job reads the staging folder that nixie's own release writes, so both come from one release
function requireReleaseBackupImage(images: NixieImages): string {
  const backupImage = images.backupImage;

  requirePinnedImage('nixie.backupImage', backupImage);

  const release = getImageTag(images.image);

  if (backupImage.slice(0, backupImage.indexOf('@')) !== `${backupRepository}:${release}`) {
    throw new Error(
      `stack config "nixie.backupImage" must name ${backupRepository}:${release}, the release of nixie.image`,
    );
  }

  return backupImage;
}

function getImageTag(image: string): string {
  const name = image.slice(0, image.indexOf('@'));

  return name.slice(name.lastIndexOf(':') + 1);
}

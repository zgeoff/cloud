import { secret } from '@pulumi/pulumi';
import type { Config } from '@pulumi/pulumi';
import { findResticBackup } from './find-restic-backup.ts';
import type { NixieBackupInputs, NixieConfig, NixieInputs } from './nixie.ts';

// the stack config methods this reads: Pulumi's Config, or a stand-in in a test
type NixieStackConfig = Pick<Config, 'getObject'>;

type Environment = Readonly<Record<string, string | undefined>>;

// nixie's inputs, or nothing while nixie is unset (setting it approves the deploy). Secrets come
// from .env's op:// references, plus Pulumi's CLOUDFLARE_API_TOKEN for the certificate's DNS-01.
// NIXIE_RESTIC_* and NIXIE_R2_* add the backup, which then needs nixie.backupImage.
export function loadNixieInputs(
  stackConfig: NixieStackConfig,
  env: Environment,
): { readonly nixie?: NixieInputs } {
  const config = stackConfig.getObject<NixieConfig>('nixie');

  if (config === undefined) {
    return {};
  }

  requirePinnedImage('image', config.image);
  requirePinnedImage('webImage', config.webImage);
  requireHostname(config.hostname);

  const backup = findBackup(config, env);

  return {
    nixie: {
      config: { image: config.image, webImage: config.webImage, hostname: config.hostname },
      secrets: {
        ageHostKey: secret(requireVariable(env, 'NIXIE_AGE_HOST_KEY')),
        definitionsDeployKey: secret(requireVariable(env, 'NIXIE_DEFINITIONS_DEPLOY_KEY')),
        dnsToken: secret(requireVariable(env, 'CLOUDFLARE_API_TOKEN')),
      },
      ...(backup === undefined ? {} : { backup }),
    },
  };
}

// a release pin names its tag for the reader and its digest for the runtime
const pinnedImagePattern = /^[^\s@:]+(?::\d+)?(?:\/[^\s@:]+)*:[^\s@:]+@sha256:[0-9a-f]{64}$/u;

// all backup variables set, or no backup; findResticBackup throws on a partial set
function findBackup(config: NixieConfig, env: Environment): NixieBackupInputs | undefined {
  const backup = findResticBackup(env, { prefix: 'NIXIE', label: "nixie's backup", path: 'nixie' });

  if (backup === undefined) {
    return undefined;
  }

  requirePinnedImage('backupImage', config.backupImage);

  return {
    image: config.backupImage,
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

function requireVariable(env: Environment, name: string): string {
  const value = env[name];

  if (value === undefined || value === '') {
    throw new Error(`${name} is unset; nixie needs it while stack config "nixie" is set`);
  }

  return value;
}

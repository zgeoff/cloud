import { secret } from '@pulumi/pulumi';
import type { Config } from '@pulumi/pulumi';
import type { NixieConfig, NixieInputs } from './nixie.ts';

// the stack config methods this reads: Pulumi's Config, or a stand-in in a test
type NixieStackConfig = Pick<Config, 'getObject'>;

type Environment = Readonly<Record<string, string | undefined>>;

// nixie's inputs, or nothing while nixie is unset (setting it approves the deploy). Secrets come
// from .env's op:// references: NIXIE_AGE_HOST_KEY and NIXIE_DEFINITIONS_DEPLOY_KEY, plus
// Pulumi's own CLOUDFLARE_API_TOKEN for the certificate's DNS challenge.
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

  return {
    nixie: {
      config: { image: config.image, webImage: config.webImage, hostname: config.hostname },
      secrets: {
        ageHostKey: secret(requireVariable(env, 'NIXIE_AGE_HOST_KEY')),
        definitionsDeployKey: secret(requireVariable(env, 'NIXIE_DEFINITIONS_DEPLOY_KEY')),
        dnsToken: secret(requireVariable(env, 'CLOUDFLARE_API_TOKEN')),
      },
    },
  };
}

// a release pin names its tag for the reader and its digest for the runtime
const pinnedImagePattern = /^[^\s@:]+(?::\d+)?(?:\/[^\s@:]+)*:[^\s@:]+@sha256:[0-9a-f]{64}$/u;

function requirePinnedImage(key: string, image: string | undefined): void {
  if (image === undefined || !pinnedImagePattern.test(image)) {
    throw new Error(`stack config "nixie.${key}" must name an image by tag and digest`);
  }
}

function requireVariable(env: Environment, name: string): string {
  const value = env[name];

  if (value === undefined || value === '') {
    throw new Error(`${name} is unset; nixie needs it while stack config "nixie" is set`);
  }

  return value;
}

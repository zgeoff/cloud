import { secret } from '@pulumi/pulumi';
import type { Output } from '@pulumi/pulumi';
import { readATCGatewayRelease } from '../shared/read-atc-gateway-release.ts';
import { findVariable } from './find-variable.ts';
import type { Environment } from './types.ts';

// the first atc release whose atc-gateway takes --service-token-file
export const serviceTokenRelease = '7.14.0';
const variable = 'BOXXY_ATC_TOKEN';

// atc's own rule: `atcs_` and 32 or more of A-Z, a-z, 0-9, _ and -
const tokenPattern = /^atcs_[\w-]{32,}$/u;

export interface ATCGatewayServiceTokenOptions {
  // the atc release that the gateway image is built from
  readonly readRelease?: () => string;

  // one line, with no secret in it
  readonly warn?: (line: string) => void;
}

// The boxxy server's token for the gateway, from the variable the boxxy server also reads. Unless
// both the source pin and the deployed image are 7.14.0 or later, the token is left out with one
// warning, and the variable need not hold the shape atc takes.
export function loadATCGatewayServiceTokens(
  env: Environment,
  image: string,
  options: ATCGatewayServiceTokenOptions = {},
): Readonly<Record<string, Output<string>>> | undefined {
  const token = findVariable(env, variable);

  if (token === undefined) {
    return undefined;
  }

  const release = (options.readRelease ?? readATCGatewayRelease)();
  const warn = options.warn ?? warnOnStderr;

  if (!isReleaseAtLeast(release, serviceTokenRelease)) {
    warn(
      `${variable} is set, but images/atc-gateway/versions.env pins atc ${release}, and --service-token-file needs ${serviceTokenRelease}: the gateway deploys without the boxxy service token`,
    );

    return undefined;
  }

  // the pin builds the next image; the stack config names the image that runs
  const imageRelease = readImageRelease(image);

  if (imageRelease === undefined || !isReleaseAtLeast(imageRelease, serviceTokenRelease)) {
    warn(
      `${variable} is set, but the stack's atcGateway.image is ${imageRelease === undefined ? 'not a release tag' : `release ${imageRelease}`}, and --service-token-file needs ${serviceTokenRelease}: the gateway deploys without the boxxy service token`,
    );

    return undefined;
  }

  // the message never holds the value
  if (!tokenPattern.test(token)) {
    throw new Error(
      `${variable} must be atcs_ followed by 32 or more of A-Z, a-z, 0-9, _ and -, the shape of an atc service token`,
    );
  }

  return { boxxy: secret(token) };
}

function warnOnStderr(line: string): void {
  process.stderr.write(`warning: ${line}\n`);
}

function isReleaseAtLeast(release: string, minimum: string): boolean {
  const parts = release.split('.').map(Number);
  const floor = minimum.split('.').map(Number);

  for (const [index, part] of parts.entries()) {
    const needed = floor[index] ?? 0;

    if (part !== needed) {
      return part > needed;
    }
  }

  return true;
}

// the release tag of a pinned image such as `ghcr.io/zgeoff/atc-gateway:7.14.0@sha256:...`
function readImageRelease(image: string): string | undefined {
  return /:(?<release>\d+\.\d+\.\d+)@/u.exec(image)?.groups?.['release'];
}

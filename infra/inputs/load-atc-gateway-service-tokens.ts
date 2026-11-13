import { secret } from '@pulumi/pulumi';
import type { Output } from '@pulumi/pulumi';
import { atcGatewayServiceClients } from '../shared/atc-gateway-service-clients.ts';
import type { ATCGatewayServiceClient } from '../shared/atc-gateway-service-clients.ts';
import { readATCGatewayRelease } from '../shared/read-atc-gateway-release.ts';
import { findVariable } from './find-variable.ts';
import type { Environment } from './types.ts';

// the first atc release whose atc-gateway takes --service-token-file
const serviceTokenRelease = '7.14.0';

// the variable each client's token comes from, which the boxxy server also reads
const variables = {
  boxxy: 'BOXXY_ATC_TOKEN',
  'boxxy-notices': 'BOXXY_ATC_NOTICE_TOKEN',
} as const satisfies Record<ATCGatewayServiceClient, string>;

// atc's own rule: `atcs_` and 32 or more of A-Z, a-z, 0-9, _ and -
const tokenPattern = /^atcs_[\w-]{32,}$/u;

export interface ATCGatewayServiceTokenOptions {
  // the atc release that the gateway image is built from
  readonly readRelease?: () => string;

  // one line, with no secret in it
  readonly warn?: (line: string) => void;
}

type ServiceTokens = Readonly<Partial<Record<ATCGatewayServiceClient, Output<string>>>>;

// The boxxy server's tokens for the gateway, from the variables the server also reads. Unless both
// the source pin and the deployed image are 7.14.0 or later, the tokens are left out with one
// warning for each, and the variables need not hold the shape atc takes.
export function loadATCGatewayServiceTokens(
  env: Environment,
  image: string,
  options: ATCGatewayServiceTokenOptions = {},
): ServiceTokens | undefined {
  const found = atcGatewayServiceClients.flatMap((name) => {
    const token = findVariable(env, variables[name]);

    return token === undefined ? [] : [{ name, variable: variables[name], token }];
  });

  if (found.length === 0) {
    return undefined;
  }

  const release = (options.readRelease ?? readATCGatewayRelease)();
  const warn = options.warn ?? warnOnStderr;
  const fault = findReleaseFault(release, image);

  if (fault !== undefined) {
    for (const entry of found) {
      warn(
        `${entry.variable} is set, but ${fault}, and --service-token-file needs ${serviceTokenRelease}: the gateway deploys without the ${entry.name} service token`,
      );
    }

    return undefined;
  }

  for (const entry of found) {
    // the message never holds the value
    if (!tokenPattern.test(entry.token)) {
      throw new Error(
        `${entry.variable} must be atcs_ followed by 32 or more of A-Z, a-z, 0-9, _ and -, the shape of an atc service token`,
      );
    }
  }

  return Object.fromEntries(found.map((entry) => [entry.name, secret(entry.token)]));
}

function warnOnStderr(line: string): void {
  process.stderr.write(`warning: ${line}\n`);
}

// why the gateway cannot take the flag, or nothing when both the pin and the image can
function findReleaseFault(release: string, image: string): string | undefined {
  if (!isReleaseAtLeast(release, serviceTokenRelease)) {
    return `images/atc-gateway/versions.env pins atc ${release}`;
  }

  // the pin builds the next image; the stack config names the image that runs
  const imageRelease = parseImageRelease(image);

  if (imageRelease === undefined) {
    return "the stack's atcGateway.image is not a release tag";
  }

  if (!isReleaseAtLeast(imageRelease, serviceTokenRelease)) {
    return `the stack's atcGateway.image is release ${imageRelease}`;
  }

  return undefined;
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
function parseImageRelease(image: string): string | undefined {
  return /:(?<release>\d+\.\d+\.\d+)@/u.exec(image)?.groups?.['release'];
}

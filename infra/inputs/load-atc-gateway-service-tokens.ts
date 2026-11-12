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

// The boxxy server's token for the gateway, from the variable the boxxy server also reads. An
// older gateway image does not know --service-token-file, so with such a pin the token is left out
// with one warning, and the variable need not hold the shape atc takes.
export function loadATCGatewayServiceTokens(
  env: Environment,
  options: ATCGatewayServiceTokenOptions = {},
): Readonly<Record<string, Output<string>>> | undefined {
  const token = findVariable(env, variable);

  if (token === undefined) {
    return undefined;
  }

  const release = (options.readRelease ?? readATCGatewayRelease)();

  if (!isReleaseAtLeast(release, serviceTokenRelease)) {
    (options.warn ?? warnOnStderr)(
      `${variable} is set, but images/atc-gateway/versions.env pins atc ${release}, and --service-token-file needs ${serviceTokenRelease}: the gateway deploys without the boxxy service token`,
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

function warnOnStderr(line: string): void {
  process.stderr.write(`warning: ${line}\n`);
}

import { readFileSync } from 'node:fs';

const releasePattern = /^ATC_RELEASE=@zgeoff\/atc@(?<version>\d+\.\d+\.\d+)$/mu;

// The atc release that images/atc-gateway/versions.env pins for the gateway binary, such as
// `7.12.1`. The stack config pins the image itself by digest, and a publish run builds that image
// from this pin.
export function readATCGatewayRelease(): string {
  return parseATCGatewayRelease(
    readFileSync(new URL('../../images/atc-gateway/versions.env', import.meta.url), 'utf8'),
  );
}

export function parseATCGatewayRelease(text: string): string {
  const version = releasePattern.exec(text)?.groups?.['version'];

  if (version === undefined) {
    throw new Error(
      'images/atc-gateway/versions.env has no ATC_RELEASE line of the form @zgeoff/atc@<major>.<minor>.<patch>',
    );
  }

  return version;
}

import { expect, test } from 'bun:test';
import { parseATCGatewayRelease, readATCGatewayRelease } from './read-atc-gateway-release.ts';

test('#parseATCGatewayRelease reads the version of the ATC_RELEASE line among the other pins', () => {
  expect(
    parseATCGatewayRelease(
      [
        '# Pins for the atc-gateway images.',
        'ATC_RELEASE=@zgeoff/atc@7.14.0',
        'ATC_ASSET=atc-gateway-linux-x64',
        'GATEWAY_IMAGE_TAG=7.14.0',
        '',
      ].join('\n'),
    ),
  ).toBe('7.14.0');
});

test.each([
  ['a file with no ATC_RELEASE line', 'GATEWAY_IMAGE_TAG=7.14.0\n'],
  ['a release with a pre-release suffix', 'ATC_RELEASE=@zgeoff/atc@7.14.0-rc.1\n'],
  ['a commented line', '# ATC_RELEASE=@zgeoff/atc@7.14.0\n'],
])('#parseATCGatewayRelease throws for %s', (_name, text) => {
  expect(() => parseATCGatewayRelease(text)).toThrowWithMessage(
    Error,
    'images/atc-gateway/versions.env has no ATC_RELEASE line of the form @zgeoff/atc@<major>.<minor>.<patch>',
  );
});

test("#readATCGatewayRelease reads the repo's own pin", () => {
  expect(readATCGatewayRelease()).toMatch(/^\d+\.\d+\.\d+$/u);
});

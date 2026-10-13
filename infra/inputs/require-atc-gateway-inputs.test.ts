// each case repeats the whole valid config, so its body is long
/* oxlint-disable max-lines */
import { expect, test } from 'bun:test';
import { requireATCGatewayInputs } from './require-atc-gateway-inputs.ts';

test('it returns the checked config and each daemon token when every input is set', () => {
  expect(
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
        backupImage: `ghcr.io/zgeoff/atc-gateway-backup:3.0.0@sha256:${'1'.repeat(64)}`,
        publicURL: 'https://atc.geoff.cloud',
        daemons: {
          geoffcloud: {
            address: '100.69.47.33:8415',
            daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
          },
          'home-pc': {
            address: '100.67.122.120:8415',
            daemonID: '1a2b2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
            alertSeverity: 'warning',
          },
        },
        defaultDaemon: 'geoffcloud',
      },
      { ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'x'.repeat(32), ATC_GATEWAY_TOKEN_HOME_PC: 'y'.repeat(32) },
    ),
  ).toStrictEqual({
    config: {
      image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
      backupImage: `ghcr.io/zgeoff/atc-gateway-backup:3.0.0@sha256:${'1'.repeat(64)}`,
      publicURL: 'https://atc.geoff.cloud',
      daemons: {
        geoffcloud: {
          address: '100.69.47.33:8415',
          daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
          alertSeverity: 'critical',
        },
        'home-pc': {
          address: '100.67.122.120:8415',
          daemonID: '1a2b2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
          alertSeverity: 'warning',
        },
      },
      defaultDaemon: 'geoffcloud',
    },
    tokens: { geoffcloud: 'x'.repeat(32), 'home-pc': 'y'.repeat(32) },
  });
});

test('it throws naming the stack config path of a field the schema rejects', () => {
  expect(() =>
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
        backupImage: `ghcr.io/zgeoff/atc-gateway-backup:3.0.0@sha256:${'1'.repeat(64)}`,
        publicURL: 'https://atc.geoff.cloud',
        daemons: { geoffcloud: { daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b' } },
        defaultDaemon: 'geoffcloud',
      },
      { ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'x'.repeat(32) },
    ),
  ).toThrowWithMessage(
    Error,
    "atcGateway.daemons.geoffcloud.address must be the daemon's tailnet host:port, such as 100.69.47.33:8415",
  );
});

test('it throws listing every field the schema rejects, one to a line', () => {
  expect(() =>
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
        publicURL: 'atc.geoff.cloud',
        daemons: {
          geoffcloud: {
            address: '100.69.47.33:8415',
            daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
          },
        },
        defaultDaemon: 'geoffcloud',
      },
      { ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'x'.repeat(32) },
    ),
  ).toThrowWithMessage(
    Error,
    'atcGateway.backupImage must name an image by tag and digest\natcGateway.publicURL must be the https:// origin clients reach, such as https://atc.geoff.cloud',
  );
});

test('it throws naming the whole stack config key when the value is not an object', () => {
  expect(() =>
    requireATCGatewayInputs('atc.geoff.cloud', { ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'x'.repeat(32) }),
  ).toThrowWithMessage(Error, 'atcGateway must be an object');
});

test('it reads the token of a daemon name from the variable atc derives from it', () => {
  expect(
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
        backupImage: `ghcr.io/zgeoff/atc-gateway-backup:3.0.0@sha256:${'1'.repeat(64)}`,
        publicURL: 'https://atc.geoff.cloud',
        daemons: {
          [`a${'1'.repeat(30)}`]: {
            address: '100.69.47.33:8415',
            daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
          },
        },
        defaultDaemon: `a${'1'.repeat(30)}`,
      },
      { [`ATC_GATEWAY_TOKEN_A${'1'.repeat(30)}`]: 'x'.repeat(32) },
    ).tokens,
  ).toStrictEqual({ [`a${'1'.repeat(30)}`]: 'x'.repeat(32) });
});

test.each([
  [
    'unset',
    undefined,
    "ATC_GATEWAY_TOKEN_GEOFFCLOUD is unset; .env must reference the daemon's token",
  ],
  ['empty', '', "ATC_GATEWAY_TOKEN_GEOFFCLOUD is blank; .env must reference the daemon's token"],
])('it refuses a token that is %s', (_kind, token, message) => {
  expect(() =>
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
        backupImage: `ghcr.io/zgeoff/atc-gateway-backup:3.0.0@sha256:${'1'.repeat(64)}`,
        publicURL: 'https://atc.geoff.cloud',
        daemons: {
          geoffcloud: {
            address: '100.69.47.33:8415',
            daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
          },
        },
        defaultDaemon: 'geoffcloud',
      },
      { ATC_GATEWAY_TOKEN_GEOFFCLOUD: token },
    ),
  ).toThrowWithMessage(Error, message);
});

// an exact match on the whole message also proves the token is not echoed
test.each([
  ['a trailing newline', `${'x'.repeat(32)}\n`],
  ['a leading space', ` ${'x'.repeat(32)}`],
  ['a trailing tab', `${'x'.repeat(32)}\t`],
  ['a carriage return', `${'x'.repeat(32)}\r`],
  ['a no-break space', `${'x'.repeat(32)} `],
  ['two tokens on two lines', `${'x'.repeat(32)}\n${'x'.repeat(32)}`],
])('it refuses, without echoing it, a token with %s', (_kind, token) => {
  expect(() =>
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
        backupImage: `ghcr.io/zgeoff/atc-gateway-backup:3.0.0@sha256:${'1'.repeat(64)}`,
        publicURL: 'https://atc.geoff.cloud',
        daemons: {
          geoffcloud: {
            address: '100.69.47.33:8415',
            daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
          },
        },
        defaultDaemon: 'geoffcloud',
      },
      { ATC_GATEWAY_TOKEN_GEOFFCLOUD: token },
    ),
  ).toThrowWithMessage(
    Error,
    'ATC_GATEWAY_TOKEN_GEOFFCLOUD must be the one token, with no whitespace',
  );
});

test.each([
  ['an 18-byte', 'short-secret-value'],
  ['a 31-byte', 'x'.repeat(31)],
  ['a 16-character, 31-byte', `${'é'.repeat(15)}x`],
])('it refuses, without echoing it, %s token', (_kind, token) => {
  expect(() =>
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
        backupImage: `ghcr.io/zgeoff/atc-gateway-backup:3.0.0@sha256:${'1'.repeat(64)}`,
        publicURL: 'https://atc.geoff.cloud',
        daemons: {
          geoffcloud: {
            address: '100.69.47.33:8415',
            daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
          },
        },
        defaultDaemon: 'geoffcloud',
      },
      { ATC_GATEWAY_TOKEN_GEOFFCLOUD: token },
    ),
  ).toThrowWithMessage(Error, 'ATC_GATEWAY_TOKEN_GEOFFCLOUD is shorter than 32 bytes');
});

test('it takes a 16-character token of 32 bytes, counting bytes, not characters', () => {
  expect(
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
        backupImage: `ghcr.io/zgeoff/atc-gateway-backup:3.0.0@sha256:${'1'.repeat(64)}`,
        publicURL: 'https://atc.geoff.cloud',
        daemons: {
          geoffcloud: {
            address: '100.69.47.33:8415',
            daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
          },
        },
        defaultDaemon: 'geoffcloud',
      },
      { ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'é'.repeat(16) },
    ).tokens,
  ).toStrictEqual({ geoffcloud: 'é'.repeat(16) });
});

test("it checks each daemon's own token variable", () => {
  expect(() =>
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
        backupImage: `ghcr.io/zgeoff/atc-gateway-backup:3.0.0@sha256:${'1'.repeat(64)}`,
        publicURL: 'https://atc.geoff.cloud',
        daemons: {
          geoffcloud: {
            address: '100.69.47.33:8415',
            daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
          },
          'home-pc': {
            address: '100.67.122.120:8415',
            daemonID: '1a2b2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
          },
        },
        defaultDaemon: 'geoffcloud',
      },
      { ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'x'.repeat(32) },
    ),
  ).toThrowWithMessage(
    Error,
    "ATC_GATEWAY_TOKEN_HOME_PC is unset; .env must reference the daemon's token",
  );
});

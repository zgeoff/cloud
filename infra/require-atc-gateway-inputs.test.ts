import { expect, test } from 'bun:test';
import { requireATCGatewayInputs } from './require-atc-gateway-inputs.ts';

test('it returns each daemon with its token, and the default, when every input is set', () => {
  expect(
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
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
  ).toStrictEqual({
    daemons: {
      geoffcloud: {
        address: '100.69.47.33:8415',
        daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
        alertSeverity: 'critical',
        token: 'x'.repeat(32),
      },
    },
    defaultDaemon: 'geoffcloud',
  });
});

test('it takes several daemons, each with the token atc derives from its name', () => {
  expect(
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
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
      { ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'x'.repeat(32), ATC_GATEWAY_TOKEN_HOME_PC: 'y'.repeat(32) },
    ),
  ).toStrictEqual({
    daemons: {
      geoffcloud: {
        address: '100.69.47.33:8415',
        daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
        alertSeverity: 'critical',
        token: 'x'.repeat(32),
      },
      'home-pc': {
        address: '100.67.122.120:8415',
        daemonID: '1a2b2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
        alertSeverity: 'critical',
        token: 'y'.repeat(32),
      },
    },
    defaultDaemon: 'geoffcloud',
  });
});

test.each([
  `ghcr.io/zgeoff/atc-gateway:2.10.0@sha256:86cd2af8f297cb5143cee19e71b921d6ba0bc3e3a004d6498be7533b34a068be`,
  'ghcr.io/zgeoff/atc-gateway:2.10.0',
])('it refuses the fixture stand-in image %s', (image) => {
  expect(() =>
    requireATCGatewayInputs(
      {
        image,
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
    `${image} is the fixture stand-in, not the gateway; wait for atc's release`,
  );
});

test('it refuses unset daemons, naming the fields they replace', () => {
  expect(() =>
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
        defaultDaemon: 'geoffcloud',
      },
      { ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'x'.repeat(32) },
    ),
  ).toThrowWithMessage(
    Error,
    'atcGateway.daemons is unset or empty: give each daemon as atcGateway.daemons.<name> with its address and daemonID (they replace atcGateway.daemonAddress and daemonID)',
  );
});

test('it refuses empty daemons, naming the fields they replace', () => {
  expect(() =>
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
        daemons: {},
        defaultDaemon: 'geoffcloud',
      },
      { ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'x'.repeat(32) },
    ),
  ).toThrowWithMessage(
    Error,
    'atcGateway.daemons is unset or empty: give each daemon as atcGateway.daemons.<name> with its address and daemonID (they replace atcGateway.daemonAddress and daemonID)',
  );
});

test.each([
  ['GeoffCloud', 'ATC_GATEWAY_TOKEN_GEOFFCLOUD'],
  ['home_pc', 'ATC_GATEWAY_TOKEN_HOME_PC'],
  ['1pc', 'ATC_GATEWAY_TOKEN_1PC'],
  ['pc-', 'ATC_GATEWAY_TOKEN_PC_'],
  ['home.pc', 'ATC_GATEWAY_TOKEN_HOME.PC'],
  ['', 'ATC_GATEWAY_TOKEN_'],
  ['a'.repeat(32), `ATC_GATEWAY_TOKEN_${'A'.repeat(32)}`],
])(
  'it refuses the daemon name %p, which is not a lowercase DNS label atc takes, even with its token in %s',
  (name, variable) => {
    expect(() =>
      requireATCGatewayInputs(
        {
          image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
          daemons: {
            [name]: {
              address: '100.69.47.33:8415',
              daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
            },
          },
          defaultDaemon: name,
        },
        { [variable]: 'x'.repeat(32) },
      ),
    ).toThrowWithMessage(
      Error,
      `atcGateway.daemons.${name}: a daemon name must be a lowercase DNS label of at most 31 characters, starting with a letter`,
    );
  },
);

test.each([
  ['a', 'ATC_GATEWAY_TOKEN_A'],
  [`a${'1'.repeat(30)}`, `ATC_GATEWAY_TOKEN_A${'1'.repeat(30)}`],
])('it takes the daemon name %s, reading its token from %s', (name, variable) => {
  expect(
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
        daemons: {
          [name]: {
            address: '100.69.47.33:8415',
            daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
          },
        },
        defaultDaemon: name,
      },
      { [variable]: 'x'.repeat(32) },
    ),
  ).toStrictEqual({
    daemons: {
      [name]: {
        address: '100.69.47.33:8415',
        daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
        alertSeverity: 'critical',
        token: 'x'.repeat(32),
      },
    },
    defaultDaemon: name,
  });
});

test('it refuses an unset defaultDaemon, listing the daemons', () => {
  expect(() =>
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
        daemons: {
          geoffcloud: {
            address: '100.69.47.33:8415',
            daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
          },
        },
      },
      { ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'x'.repeat(32) },
    ),
  ).toThrowWithMessage(
    Error,
    'atcGateway.defaultDaemon is unset: name the daemon a call without one goes to, one of geoffcloud',
  );
});

test('it refuses an empty defaultDaemon, listing the daemons', () => {
  expect(() =>
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
        daemons: {
          geoffcloud: {
            address: '100.69.47.33:8415',
            daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
          },
        },
        defaultDaemon: '',
      },
      { ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'x'.repeat(32) },
    ),
  ).toThrowWithMessage(
    Error,
    'atcGateway.defaultDaemon is unset: name the daemon a call without one goes to, one of geoffcloud',
  );
});

test('it refuses a defaultDaemon that is not among the daemons', () => {
  expect(() =>
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
        daemons: {
          geoffcloud: {
            address: '100.69.47.33:8415',
            daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
          },
        },
        defaultDaemon: 'home-pc',
      },
      { ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'x'.repeat(32) },
    ),
  ).toThrowWithMessage(
    Error,
    "atcGateway.defaultDaemon 'home-pc' is not in atcGateway.daemons (geoffcloud)",
  );
});

test('it lists every daemon when the defaultDaemon is not among them', () => {
  expect(() =>
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
        daemons: {
          geoffcloud: {
            address: '100.69.47.33:8415',
            daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
          },
          'home-pc': {
            address: '100.101.12.7:8415',
            daemonID: '7c3e9a1b-2d4f-4a6c-8e0b-5f1a2c3d4e5f',
          },
        },
        defaultDaemon: 'laptop',
      },
      { ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'x'.repeat(32), ATC_GATEWAY_TOKEN_HOME_PC: 'y'.repeat(32) },
    ),
  ).toThrowWithMessage(
    Error,
    "atcGateway.defaultDaemon 'laptop' is not in atcGateway.daemons (geoffcloud, home-pc)",
  );
});

test("it takes atc's limit of 34 daemons", () => {
  const names = Array.from({ length: 34 }, (_, index) => `d${index}`);

  const daemons = Object.fromEntries(
    names.map((name) => [
      name,
      { address: '100.69.47.33:8415', daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b' },
    ]),
  );

  const env = Object.fromEntries(
    names.map((name) => [`ATC_GATEWAY_TOKEN_${name.toUpperCase()}`, 'x'.repeat(32)]),
  );

  expect(
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
        daemons,
        defaultDaemon: 'd0',
      },
      env,
    ),
  ).toStrictEqual({
    daemons: Object.fromEntries(
      names.map((name) => [
        name,
        {
          address: '100.69.47.33:8415',
          daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
          alertSeverity: 'critical',
          token: 'x'.repeat(32),
        },
      ]),
    ),
    defaultDaemon: 'd0',
  });
});

test("it refuses 35 daemons, over atc's limit of 34", () => {
  const names = Array.from({ length: 35 }, (_, index) => `d${index}`);

  const daemons = Object.fromEntries(
    names.map((name) => [
      name,
      { address: '100.69.47.33:8415', daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b' },
    ]),
  );

  const env = Object.fromEntries(
    names.map((name) => [`ATC_GATEWAY_TOKEN_${name.toUpperCase()}`, 'x'.repeat(32)]),
  );

  expect(() =>
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
        daemons,
        defaultDaemon: 'd0',
      },
      env,
    ),
  ).toThrowWithMessage(
    Error,
    "atcGateway.daemons lists 35 daemons, over atc's limit of 34: the gateway refuses such a registry and exits at start",
  );
});

test('it refuses to deploy a daemon with no daemonID', () => {
  expect(() =>
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
        daemons: { geoffcloud: { address: '100.69.47.33:8415' } },
        defaultDaemon: 'geoffcloud',
      },
      { ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'x'.repeat(32) },
    ),
  ).toThrowWithMessage(
    Error,
    'atcGateway.daemons.geoffcloud.daemonID is unset: pin the daemon with the output of `atc daemon id` on its host',
  );
});

test('it refuses to deploy a daemon with an empty daemonID', () => {
  expect(() =>
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
        daemons: { geoffcloud: { address: '100.69.47.33:8415', daemonID: '' } },
        defaultDaemon: 'geoffcloud',
      },
      { ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'x'.repeat(32) },
    ),
  ).toThrowWithMessage(
    Error,
    'atcGateway.daemons.geoffcloud.daemonID is unset: pin the daemon with the output of `atc daemon id` on its host',
  );
});

test.each(['0F8E2C1A-4B6D-4E3F-9A7B-1C2D3E4F5A6B', 'geoffcloud'])(
  'it refuses the daemonID %s, which is not a lowercase UUID',
  (daemonID) => {
    expect(() =>
      requireATCGatewayInputs(
        {
          image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
          daemons: { geoffcloud: { address: '100.69.47.33:8415', daemonID } },
          defaultDaemon: 'geoffcloud',
        },
        { ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'x'.repeat(32) },
      ),
    ).toThrowWithMessage(
      Error,
      'atcGateway.daemons.geoffcloud.daemonID must be a lowercase UUID, as `atc daemon id` prints it',
    );
  },
);

test('it refuses a daemon with no address', () => {
  expect(() =>
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
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

test('it refuses a daemon entry that is undefined, naming its address first', () => {
  expect(() =>
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
        daemons: { geoffcloud: undefined },
        defaultDaemon: 'geoffcloud',
      },
      { ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'x'.repeat(32) },
    ),
  ).toThrowWithMessage(
    Error,
    "atcGateway.daemons.geoffcloud.address must be the daemon's tailnet host:port, such as 100.69.47.33:8415",
  );
});

test.each([
  '',
  '100.69.47.33',
  '100.69.47.33:',
  '100.69.47.33:0',
  '100.69.47.33:65536',
  '100.69.47.33:123456',
  ':8415',
  'fd7a::1:8415',
])('it refuses the daemon address %p', (address) => {
  expect(() =>
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
        daemons: {
          geoffcloud: { address, daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b' },
        },
        defaultDaemon: 'geoffcloud',
      },
      { ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'x'.repeat(32) },
    ),
  ).toThrowWithMessage(
    Error,
    "atcGateway.daemons.geoffcloud.address must be the daemon's tailnet host:port, such as 100.69.47.33:8415",
  );
});

test.each(['100.69.47.33:1', '100.69.47.33:65535', '[fd7a::1]:8415', 'geoffcloud:8415'])(
  'it takes the daemon address %s',
  (address) => {
    expect(
      requireATCGatewayInputs(
        {
          image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
          daemons: {
            geoffcloud: { address, daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b' },
          },
          defaultDaemon: 'geoffcloud',
        },
        { ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'x'.repeat(32) },
      ),
    ).toStrictEqual({
      daemons: {
        geoffcloud: {
          address,
          daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
          alertSeverity: 'critical',
          token: 'x'.repeat(32),
        },
      },
      defaultDaemon: 'geoffcloud',
    });
  },
);

test.each(['critical', 'warning'] as const)("it takes a daemon's alertSeverity %s", (severity) => {
  expect(
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
        daemons: {
          geoffcloud: {
            address: '100.69.47.33:8415',
            daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
            alertSeverity: severity,
          },
        },
        defaultDaemon: 'geoffcloud',
      },
      { ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'x'.repeat(32) },
    ),
  ).toStrictEqual({
    daemons: {
      geoffcloud: {
        address: '100.69.47.33:8415',
        daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
        alertSeverity: severity,
        token: 'x'.repeat(32),
      },
    },
    defaultDaemon: 'geoffcloud',
  });
});

test('it refuses an alertSeverity other than critical or warning', () => {
  expect(() =>
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
        daemons: {
          geoffcloud: {
            address: '100.69.47.33:8415',
            daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
            alertSeverity: 'page',
          },
        },
        defaultDaemon: 'geoffcloud',
      },
      { ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'x'.repeat(32) },
    ),
  ).toThrowWithMessage(
    Error,
    'atcGateway.daemons.geoffcloud.alertSeverity must be critical or warning, got page',
  );
});

test('it refuses an empty alertSeverity', () => {
  expect(() =>
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
        daemons: {
          geoffcloud: {
            address: '100.69.47.33:8415',
            daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
            alertSeverity: '',
          },
        },
        defaultDaemon: 'geoffcloud',
      },
      { ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'x'.repeat(32) },
    ),
  ).toThrowWithMessage(
    Error,
    'atcGateway.daemons.geoffcloud.alertSeverity must be critical or warning, got ',
  );
});

test.each([
  ['missing', undefined],
  ['empty', ''],
])('it refuses a %s token', (_kind, token) => {
  expect(() =>
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
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
    "ATC_GATEWAY_TOKEN_GEOFFCLOUD is empty: .env must reference the daemon's token",
  );
});

// an exact match on the whole message also proves the token is not echoed
test.each([
  ['a trailing newline', `${'x'.repeat(32)}\n`],
  ['a leading space', ` ${'x'.repeat(32)}`],
  ['a trailing tab', `${'x'.repeat(32)}\t`],
  ['a carriage return', `${'x'.repeat(32)}\r`],
  ['a no-break space', `${'x'.repeat(32)} `],
  ['two tokens on two lines', `${'x'.repeat(32)}\n${'x'.repeat(32)}`],
])('it refuses, without echoing it, a token with %s', (_kind, token) => {
  expect(() =>
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
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
        daemons: {
          geoffcloud: {
            address: '100.69.47.33:8415',
            daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
          },
        },
        defaultDaemon: 'geoffcloud',
      },
      { ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'é'.repeat(16) },
    ),
  ).toStrictEqual({
    daemons: {
      geoffcloud: {
        address: '100.69.47.33:8415',
        daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
        alertSeverity: 'critical',
        token: 'é'.repeat(16),
      },
    },
    defaultDaemon: 'geoffcloud',
  });
});

test("it checks each daemon's own token variable", () => {
  expect(() =>
    requireATCGatewayInputs(
      {
        image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
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
    "ATC_GATEWAY_TOKEN_HOME_PC is empty: .env must reference the daemon's token",
  );
});

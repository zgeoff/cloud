import { expect, test } from 'bun:test';
import { atcGatewayConfigSchema } from './atc-gateway-config-schema.ts';
import type { ATCGatewayRawConfig } from './types.ts';

test('it passes a config through as given', () => {
  const payload: ATCGatewayRawConfig = {
    image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
    backupImage: `ghcr.io/zgeoff/atc-gateway-backup:3.0.0-r2@sha256:${'1'.repeat(64)}`,
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
    stateDir: '/var/lib/atc',
  };

  expect(atcGatewayConfigSchema.safeParse(payload).data).toStrictEqual(payload);
});

test('it gives a daemon with no alertSeverity the severity critical', () => {
  expect(
    atcGatewayConfigSchema.safeParse({
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
    }).data,
  ).toStrictEqual({
    image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
    backupImage: `ghcr.io/zgeoff/atc-gateway-backup:3.0.0@sha256:${'1'.repeat(64)}`,
    publicURL: 'https://atc.geoff.cloud',
    daemons: {
      geoffcloud: {
        address: '100.69.47.33:8415',
        daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
        alertSeverity: 'critical',
      },
    },
    defaultDaemon: 'geoffcloud',
  });
});

test('it rejects a config that is not an object', () => {
  expect(atcGatewayConfigSchema.safeParse('atc.geoff.cloud').error?.issues).toPartiallyContain({
    path: [],
    message: 'must be an object',
  });
});

test.each([
  ['unset', undefined],
  ['a tag with no digest', 'ghcr.io/zgeoff/atc-gateway:3.0.0'],
  ['a digest with no tag', `ghcr.io/zgeoff/atc-gateway@sha256:${'0'.repeat(64)}`],
])('it rejects an image that is %s', (_kind, image) => {
  const result = atcGatewayConfigSchema.safeParse({
    image,
    backupImage: `ghcr.io/zgeoff/atc-gateway-backup:3.0.0@sha256:${'1'.repeat(64)}`,
    publicURL: 'https://atc.geoff.cloud',
    daemons: {
      geoffcloud: {
        address: '100.69.47.33:8415',
        daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
      },
    },
    defaultDaemon: 'geoffcloud',
  });

  expect(result.error?.issues).toPartiallyContain({
    path: ['image'],
    message: 'must name an image by tag and digest',
  });
});

test('it rejects the fixture stand-in image', () => {
  const result = atcGatewayConfigSchema.safeParse({
    image:
      'ghcr.io/zgeoff/atc-gateway:2.10.0@sha256:86cd2af8f297cb5143cee19e71b921d6ba0bc3e3a004d6498be7533b34a068be',
    backupImage: `ghcr.io/zgeoff/atc-gateway-backup:3.0.0@sha256:${'1'.repeat(64)}`,
    publicURL: 'https://atc.geoff.cloud',
    daemons: {
      geoffcloud: {
        address: '100.69.47.33:8415',
        daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
      },
    },
    defaultDaemon: 'geoffcloud',
  });

  expect(result.error?.issues).toPartiallyContain({
    path: ['image'],
    message: "is the fixture stand-in, not the gateway; wait for atc's release",
  });
});

test.each([
  ['unset', undefined],
  ['a tag with no digest', 'ghcr.io/zgeoff/atc-gateway-backup:2.24.0-r2'],
])('it rejects a backupImage that is %s', (_kind, backupImage) => {
  const result = atcGatewayConfigSchema.safeParse({
    image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
    backupImage,
    publicURL: 'https://atc.geoff.cloud',
    daemons: {
      geoffcloud: {
        address: '100.69.47.33:8415',
        daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
      },
    },
    defaultDaemon: 'geoffcloud',
  });

  expect(result.error?.issues).toPartiallyContain({
    path: ['backupImage'],
    message: 'must name an image by tag and digest',
  });
});

test.each([
  ['unset', undefined],
  ['a bare host', 'atc.geoff.cloud'],
  ['plain http', 'http://atc.geoff.cloud'],
])('it rejects a publicURL that is %s', (_kind, publicURL) => {
  const result = atcGatewayConfigSchema.safeParse({
    image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
    backupImage: `ghcr.io/zgeoff/atc-gateway-backup:3.0.0@sha256:${'1'.repeat(64)}`,
    publicURL,
    daemons: {
      geoffcloud: {
        address: '100.69.47.33:8415',
        daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
      },
    },
    defaultDaemon: 'geoffcloud',
  });

  expect(result.error?.issues).toPartiallyContain({
    path: ['publicURL'],
    message: 'must be the https:// origin clients reach, such as https://atc.geoff.cloud',
  });
});

test.each([
  ['unset', undefined],
  ['empty', {}],
])('it rejects daemons that are %s, naming the fields they replace', (_kind, daemons) => {
  const result = atcGatewayConfigSchema.safeParse({
    image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
    backupImage: `ghcr.io/zgeoff/atc-gateway-backup:3.0.0@sha256:${'1'.repeat(64)}`,
    publicURL: 'https://atc.geoff.cloud',
    daemons,
    defaultDaemon: 'geoffcloud',
  });

  expect(result.error?.issues).toPartiallyContain({
    path: ['daemons'],
    message:
      'is unset or empty: give each daemon as atcGateway.daemons.<name> with its address and daemonID (they replace atcGateway.daemonAddress and daemonID)',
  });
});

test("it takes atc's limit of 34 daemons", () => {
  const daemons = Object.fromEntries(
    Array.from({ length: 34 }, (_, index) => [
      `d${index}`,
      { address: '100.69.47.33:8415', daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b' },
    ]),
  );

  const result = atcGatewayConfigSchema.safeParse({
    image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
    backupImage: `ghcr.io/zgeoff/atc-gateway-backup:3.0.0@sha256:${'1'.repeat(64)}`,
    publicURL: 'https://atc.geoff.cloud',
    daemons,
    defaultDaemon: 'd0',
  });

  expect(Object.keys(result.data?.daemons ?? {})).toHaveLength(34);
});

test("it rejects 35 daemons, over atc's limit of 34", () => {
  const daemons = Object.fromEntries(
    Array.from({ length: 35 }, (_, index) => [
      `d${index}`,
      { address: '100.69.47.33:8415', daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b' },
    ]),
  );

  const result = atcGatewayConfigSchema.safeParse({
    image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
    backupImage: `ghcr.io/zgeoff/atc-gateway-backup:3.0.0@sha256:${'1'.repeat(64)}`,
    publicURL: 'https://atc.geoff.cloud',
    daemons,
    defaultDaemon: 'd0',
  });

  expect(result.error?.issues).toPartiallyContain({
    path: ['daemons'],
    message:
      "lists 35 daemons, over atc's limit of 34: the gateway refuses such a registry and exits at start",
  });
});

test.each(['GeoffCloud', 'home_pc', '1pc', 'pc-', 'home.pc', '', 'a'.repeat(32)])(
  'it rejects the daemon name %p, which is not a lowercase DNS label atc takes',
  (name) => {
    const result = atcGatewayConfigSchema.safeParse({
      image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
      backupImage: `ghcr.io/zgeoff/atc-gateway-backup:3.0.0@sha256:${'1'.repeat(64)}`,
      publicURL: 'https://atc.geoff.cloud',
      daemons: {
        [name]: { address: '100.69.47.33:8415', daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b' },
      },
      defaultDaemon: name,
    });

    expect(result.error?.issues).toPartiallyContain({
      path: ['daemons', name],
      message:
        'is not a daemon name: a daemon name must be a lowercase DNS label of at most 31 characters, starting with a letter',
    });
  },
);

test.each(['a', `a${'1'.repeat(30)}`])('it takes the daemon name %s', (name) => {
  const result = atcGatewayConfigSchema.safeParse({
    image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
    backupImage: `ghcr.io/zgeoff/atc-gateway-backup:3.0.0@sha256:${'1'.repeat(64)}`,
    publicURL: 'https://atc.geoff.cloud',
    daemons: {
      [name]: { address: '100.69.47.33:8415', daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b' },
    },
    defaultDaemon: name,
  });

  expect(Object.keys(result.data?.daemons ?? {})).toStrictEqual([name]);
});

test('it rejects a daemon entry that is not an object', () => {
  const result = atcGatewayConfigSchema.safeParse({
    image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
    backupImage: `ghcr.io/zgeoff/atc-gateway-backup:3.0.0@sha256:${'1'.repeat(64)}`,
    publicURL: 'https://atc.geoff.cloud',
    daemons: { geoffcloud: null },
    defaultDaemon: 'geoffcloud',
  });

  expect(result.error?.issues).toPartiallyContain({
    path: ['daemons', 'geoffcloud'],
    message: "must be an object with the daemon's address and daemonID",
  });
});

test.each([
  ['unset', undefined],
  ['empty', ''],
])('it rejects a daemonID that is %s', (_kind, daemonID) => {
  const result = atcGatewayConfigSchema.safeParse({
    image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
    backupImage: `ghcr.io/zgeoff/atc-gateway-backup:3.0.0@sha256:${'1'.repeat(64)}`,
    publicURL: 'https://atc.geoff.cloud',
    daemons: { geoffcloud: { address: '100.69.47.33:8415', daemonID } },
    defaultDaemon: 'geoffcloud',
  });

  expect(result.error?.issues).toPartiallyContain({
    path: ['daemons', 'geoffcloud', 'daemonID'],
    message: 'is unset: pin the daemon with the output of `atc daemon id` on its host',
  });
});

test.each(['0F8E2C1A-4B6D-4E3F-9A7B-1C2D3E4F5A6B', 'geoffcloud'])(
  'it rejects the daemonID %s, which is not a lowercase UUID',
  (daemonID) => {
    const result = atcGatewayConfigSchema.safeParse({
      image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
      backupImage: `ghcr.io/zgeoff/atc-gateway-backup:3.0.0@sha256:${'1'.repeat(64)}`,
      publicURL: 'https://atc.geoff.cloud',
      daemons: { geoffcloud: { address: '100.69.47.33:8415', daemonID } },
      defaultDaemon: 'geoffcloud',
    });

    expect(result.error?.issues).toPartiallyContain({
      path: ['daemons', 'geoffcloud', 'daemonID'],
      message: 'must be a lowercase UUID, as `atc daemon id` prints it',
    });
  },
);

test.each([
  undefined,
  '',
  '100.69.47.33',
  '100.69.47.33:',
  '100.69.47.33:0',
  '100.69.47.33:65536',
  '100.69.47.33:123456',
  ':8415',
  'fd7a::1:8415',
])('it rejects the daemon address %p', (address) => {
  const result = atcGatewayConfigSchema.safeParse({
    image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
    backupImage: `ghcr.io/zgeoff/atc-gateway-backup:3.0.0@sha256:${'1'.repeat(64)}`,
    publicURL: 'https://atc.geoff.cloud',
    daemons: { geoffcloud: { address, daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b' } },
    defaultDaemon: 'geoffcloud',
  });

  expect(result.error?.issues).toPartiallyContain({
    path: ['daemons', 'geoffcloud', 'address'],
    message: "must be the daemon's tailnet host:port, such as 100.69.47.33:8415",
  });
});

test.each(['100.69.47.33:1', '100.69.47.33:65535', '[fd7a::1]:8415', 'geoffcloud:8415'])(
  'it takes the daemon address %s',
  (address) => {
    const result = atcGatewayConfigSchema.safeParse({
      image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
      backupImage: `ghcr.io/zgeoff/atc-gateway-backup:3.0.0@sha256:${'1'.repeat(64)}`,
      publicURL: 'https://atc.geoff.cloud',
      daemons: { geoffcloud: { address, daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b' } },
      defaultDaemon: 'geoffcloud',
    });

    expect(result.data?.daemons['geoffcloud']?.address).toBe(address);
  },
);

test.each([
  ['Critical', 'must be critical or warning, got Critical'],
  ['', 'must be critical or warning, got '],
])('it rejects the alertSeverity %p', (alertSeverity, message) => {
  const result = atcGatewayConfigSchema.safeParse({
    image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
    backupImage: `ghcr.io/zgeoff/atc-gateway-backup:3.0.0@sha256:${'1'.repeat(64)}`,
    publicURL: 'https://atc.geoff.cloud',
    daemons: {
      geoffcloud: {
        address: '100.69.47.33:8415',
        daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
        alertSeverity,
      },
    },
    defaultDaemon: 'geoffcloud',
  });

  expect(result.error?.issues).toPartiallyContain({
    path: ['daemons', 'geoffcloud', 'alertSeverity'],
    message,
  });
});

test.each([
  ['unset', undefined],
  ['empty', ''],
])('it rejects a defaultDaemon that is %s', (_kind, defaultDaemon) => {
  const result = atcGatewayConfigSchema.safeParse({
    image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
    backupImage: `ghcr.io/zgeoff/atc-gateway-backup:3.0.0@sha256:${'1'.repeat(64)}`,
    publicURL: 'https://atc.geoff.cloud',
    daemons: {
      geoffcloud: {
        address: '100.69.47.33:8415',
        daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
      },
    },
    defaultDaemon,
  });

  expect(result.error?.issues).toPartiallyContain({
    path: ['defaultDaemon'],
    message: 'is unset: name the daemon a call without one goes to, one of atcGateway.daemons',
  });
});

test('it rejects a defaultDaemon that is not among the daemons, listing them', () => {
  const result = atcGatewayConfigSchema.safeParse({
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
    defaultDaemon: 'laptop',
  });

  expect(result.error?.issues).toPartiallyContain({
    path: ['defaultDaemon'],
    message: "'laptop' is not in atcGateway.daemons (geoffcloud, home-pc)",
  });
});

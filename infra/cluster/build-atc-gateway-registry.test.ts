import { expect, test } from 'bun:test';
import { buildATCGatewayRegistry } from './build-atc-gateway-registry.ts';

test("it writes one daemon in atc's registry format", () => {
  expect(
    buildATCGatewayRegistry(
      {
        geoffcloud: {
          address: '100.69.47.33:8415',
          daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
        },
      },
      'geoffcloud',
    ),
  ).toStrictEqual({
    daemons: {
      geoffcloud: {
        address: '100.69.47.33:8415',
        daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
      },
    },
    defaultDaemon: 'geoffcloud',
  });
});

test('it pins every daemon and names the default', () => {
  expect(
    buildATCGatewayRegistry(
      {
        geoffcloud: {
          address: '100.69.47.33:8415',
          daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
        },
        'home-pc': {
          address: '100.67.122.120:8415',
          daemonID: '1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d',
        },
      },
      'home-pc',
    ),
  ).toStrictEqual({
    daemons: {
      geoffcloud: {
        address: '100.69.47.33:8415',
        daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
      },
      'home-pc': {
        address: '100.67.122.120:8415',
        daemonID: '1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d',
      },
    },
    defaultDaemon: 'home-pc',
  });
});

test('it keeps the daemons in the order they are given', () => {
  const registry = buildATCGatewayRegistry(
    {
      'home-pc': {
        address: '100.67.122.120:8415',
        daemonID: '1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d',
      },
      geoffcloud: {
        address: '100.69.47.33:8415',
        daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
      },
    },
    'geoffcloud',
  );

  expect(Object.keys(registry.daemons)).toStrictEqual(['home-pc', 'geoffcloud']);
});

test('it copies only address and daemonID', () => {
  const daemon = {
    address: '100.69.47.33:8415',
    daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
    token: 'never-in-the-registry',
  };

  expect(buildATCGatewayRegistry({ geoffcloud: daemon }, 'geoffcloud')).toStrictEqual({
    daemons: {
      geoffcloud: {
        address: '100.69.47.33:8415',
        daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
      },
    },
    defaultDaemon: 'geoffcloud',
  });
});

test('it writes an empty daemon map as given', () => {
  expect(buildATCGatewayRegistry({}, 'geoffcloud')).toStrictEqual({
    daemons: {},
    defaultDaemon: 'geoffcloud',
  });
});

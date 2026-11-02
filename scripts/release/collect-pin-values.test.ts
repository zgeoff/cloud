import { expect, test } from 'bun:test';
import { getReleaseRecord } from '../test-utils/get-release-record.ts';
import { collectPinValues } from './collect-pin-values.ts';

test('it collects each pin line part by pin id and group', () => {
  expect(
    collectPinValues(getReleaseRecord('nixie'), {
      'infra/Pulumi.prod.yaml': `nixie:\n    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:${'a'.repeat(64)}\n    webImage: ghcr.io/zgeoff/nixie-web:0.7.1@sha256:${'b'.repeat(64)}\n`,
      'package.json': '{\n  "devDependencies": {\n    "@heynixie/contract": "0.7.0"\n  }\n}\n',
    }),
  ).toStrictEqual({
    nixie: { version: '0.7.0', digest: `sha256:${'a'.repeat(64)}` },
    'nixie-web': { version: '0.7.1', digest: `sha256:${'b'.repeat(64)}` },
    'nixie-contract': { version: '0.7.0' },
  });
});

test('it refuses two lines of one pin that hold different values for one group', () => {
  expect(
    collectPinValues(getReleaseRecord('imp'), {
      'nixos/flake.nix': '      url = "github:zgeoff/impz/c5bea940";\n',
      'nixos/hosts/geoffcloud/configuration.nix': `    image = "ghcr.io/zgeoff/imp-host:1.0.1@sha256:${'3'.repeat(64)}";\n    impRegistryImage = "ghcr.io/zgeoff/imp-base:1.0.0@sha256:${'2'.repeat(64)}";\n`,
      'images/agent/Dockerfile': `FROM ghcr.io/zgeoff/imp-base:1.0.1@sha256:${'2'.repeat(64)}\n`,
    }),
  ).toStrictEqual(new Error('imp-base holds 1.0.1 and 1.0.0 for version'));
});

test('it refuses a pin line that the files lack', () => {
  expect(
    collectPinValues(getReleaseRecord('nixie'), {
      'infra/Pulumi.prod.yaml': `nixie:\n    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:${'a'.repeat(64)}\n`,
    }),
  ).toStrictEqual(
    new Error(
      String.raw`infra/Pulumi.prod.yaml has 0 lines that match '^ +webImage: ghcr\.io\/zgeoff\/nixie-web:(?<version>\d+\.\d+\.\d+)@(?<digest>sha256:[0-9a-f]{64})$', want 1`,
    ),
  );
});

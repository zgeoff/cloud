import { expect, test } from 'bun:test';
import { getReleaseRecord as getRecord } from '../test-utils/get-release-record.ts';
import { planPinEdits } from './plan-pin-edits.ts';

test('it pins an atc release in the agent image, the daemon and the gateway', () => {
  const plan = planPinEdits({
    record: getRecord('atc'),
    version: '5.0.0',
    values: {
      sha256sums: `${'4'.repeat(64)}  atc-linux-x64\n${'5'.repeat(64)}  atc-gateway-linux-x64\n`,
    },
    files: {
      'images/agent/Dockerfile': `FROM base\nARG ATC_VERSION=4.2.0\nARG ATC_SHA256=${'1'.repeat(64)}\n`,
      'nixos/packages/atc.nix': `let\n  version = "4.2.0";\n  sha256 = "${'2'.repeat(64)}";\nin\n`,
      'images/atc-gateway/versions.env': `ATC_RELEASE=@zgeoff/atc@4.2.0\nATC_ASSET=atc-gateway-linux-x64\nATC_ASSET_SHA256=${'3'.repeat(64)}\nGATEWAY_IMAGE_TAG=4.2.0-r1\n`,
    },
  });

  expect(plan).toStrictEqual({
    files: {
      'images/agent/Dockerfile': `FROM base\nARG ATC_VERSION=5.0.0\nARG ATC_SHA256=${'4'.repeat(64)}\n`,
      'nixos/packages/atc.nix': `let\n  version = "5.0.0";\n  sha256 = "${'4'.repeat(64)}";\nin\n`,
      'images/atc-gateway/versions.env': `ATC_RELEASE=@zgeoff/atc@5.0.0\nATC_ASSET=atc-gateway-linux-x64\nATC_ASSET_SHA256=${'5'.repeat(64)}\nGATEWAY_IMAGE_TAG=5.0.0\n`,
    },
    notes: ['pinned atc-agent 5.0.0', 'pinned atc-daemon 5.0.0', 'pinned atc-gateway 5.0.0'],
    written: getRecord('atc').pins,
  });
});

test('it moves an image tag pin with no version to the published tag and digest', () => {
  const plan = planPinEdits({
    record: getRecord('atc-gateway-images'),
    version: '7.1.0',
    values: {
      tags: { 'atc-gateway': '7.1.0', 'atc-gateway-backup': '3.1.0-r2' },
      digests: {
        'atc-gateway': `sha256:${'1'.repeat(64)}`,
        'atc-gateway-backup': `sha256:${'4'.repeat(64)}`,
      },
    },
    files: {
      'infra/Pulumi.prod.yaml': `    image: ghcr.io/zgeoff/atc-gateway:7.1.0@sha256:${'1'.repeat(64)}\n    backupImage: ghcr.io/zgeoff/atc-gateway-backup:3.1.0-r1@sha256:${'2'.repeat(64)}\n`,
    },
  });

  expect(plan).toStrictEqual({
    files: {
      'infra/Pulumi.prod.yaml': `    image: ghcr.io/zgeoff/atc-gateway:7.1.0@sha256:${'1'.repeat(64)}\n    backupImage: ghcr.io/zgeoff/atc-gateway-backup:3.1.0-r2@sha256:${'4'.repeat(64)}\n`,
    },
    notes: [
      'atc-gateway-image already pins 7.1.0',
      `pinned atc-gateway-backup-image 3.1.0-r2 sha256:${'4'.repeat(64)}`,
    ],
    written: getRecord('atc-gateway-images').pins.slice(1),
  });
});

test('it refuses an image tag pin without the published tag', () => {
  expect(
    planPinEdits({
      record: getRecord('atc-gateway-images'),
      version: '7.1.0',
      values: {
        tags: { 'atc-gateway': '7.1.0' },
        digests: {
          'atc-gateway': `sha256:${'1'.repeat(64)}`,
          'atc-gateway-backup': `sha256:${'4'.repeat(64)}`,
        },
      },
      files: {
        'infra/Pulumi.prod.yaml': `    image: ghcr.io/zgeoff/atc-gateway:7.1.0@sha256:${'1'.repeat(64)}\n    backupImage: ghcr.io/zgeoff/atc-gateway-backup:3.1.0-r1@sha256:${'2'.repeat(64)}\n`,
      },
    }),
  ).toStrictEqual(new Error('the release names no atc-gateway-backup tag'));
});

test('it keeps a newer pin and pins the other files', () => {
  const plan = planPinEdits({
    record: getRecord('atc'),
    version: '4.3.0',
    values: {
      sha256sums: `${'4'.repeat(64)}  atc-linux-x64\n${'5'.repeat(64)}  atc-gateway-linux-x64\n`,
    },
    files: {
      'images/agent/Dockerfile': `ARG ATC_VERSION=4.2.0\nARG ATC_SHA256=${'1'.repeat(64)}\n`,
      'nixos/packages/atc.nix': `  version = "4.2.0";\n  sha256 = "${'2'.repeat(64)}";\n`,
      'images/atc-gateway/versions.env': `ATC_RELEASE=@zgeoff/atc@4.4.0\nATC_ASSET=atc-gateway-linux-x64\nATC_ASSET_SHA256=${'3'.repeat(64)}\nGATEWAY_IMAGE_TAG=4.4.0\n`,
    },
  });

  if (plan instanceof Error) {
    throw plan;
  }

  expect([Object.keys(plan.files), plan.notes]).toStrictEqual([
    ['images/agent/Dockerfile', 'nixos/packages/atc.nix'],
    [
      'pinned atc-agent 4.3.0',
      'pinned atc-daemon 4.3.0',
      'atc-gateway pins 4.4.0, which is newer than 4.3.0',
    ],
  ]);
});

test('it reports a release that every file already pins and changes no file', () => {
  const plan = planPinEdits({
    record: getRecord('atc'),
    version: '4.2.0',
    values: {
      sha256sums: `${'1'.repeat(64)}  atc-linux-x64\n${'3'.repeat(64)}  atc-gateway-linux-x64\n`,
    },
    files: {
      'images/agent/Dockerfile': `ARG ATC_VERSION=4.2.0\nARG ATC_SHA256=${'1'.repeat(64)}\n`,
      'nixos/packages/atc.nix': `  version = "4.2.0";\n  sha256 = "${'1'.repeat(64)}";\n`,
      'images/atc-gateway/versions.env': `ATC_RELEASE=@zgeoff/atc@4.2.0\nATC_ASSET=atc-gateway-linux-x64\nATC_ASSET_SHA256=${'3'.repeat(64)}\nGATEWAY_IMAGE_TAG=4.2.0\n`,
    },
  });

  expect(plan).toStrictEqual({
    files: {},
    notes: [
      'atc-agent already pins 4.2.0',
      'atc-daemon already pins 4.2.0',
      'atc-gateway already pins 4.2.0',
    ],
    written: [],
  });
});

test('it refuses a release pinned with another sum', () => {
  expect(
    planPinEdits({
      record: getRecord('atc'),
      version: '4.2.0',
      values: {
        sha256sums: `${'9'.repeat(64)}  atc-linux-x64\n${'3'.repeat(64)}  atc-gateway-linux-x64\n`,
      },
      files: {
        'images/agent/Dockerfile': `ARG ATC_VERSION=4.3.0\nARG ATC_SHA256=${'1'.repeat(64)}\n`,
        'nixos/packages/atc.nix': `  version = "4.2.0";\n  sha256 = "${'1'.repeat(64)}";\n`,
        'images/atc-gateway/versions.env': `ATC_RELEASE=@zgeoff/atc@4.1.0\nATC_ASSET=atc-gateway-linux-x64\nATC_ASSET_SHA256=${'3'.repeat(64)}\nGATEWAY_IMAGE_TAG=4.1.0\n`,
      },
    }),
  ).toStrictEqual(
    new Error(
      `atc-daemon pins 4.2.0 with ${'1'.repeat(64)}, but the release lists ${'9'.repeat(64)}`,
    ),
  );
});

test('it refuses sums without the gateway asset', () => {
  expect(
    planPinEdits({
      record: getRecord('atc'),
      version: '5.0.0',
      values: { sha256sums: `${'4'.repeat(64)}  atc-linux-x64\n` },
      files: {
        'images/agent/Dockerfile': `ARG ATC_VERSION=4.2.0\nARG ATC_SHA256=${'1'.repeat(64)}\n`,
        'nixos/packages/atc.nix': `  version = "4.2.0";\n  sha256 = "${'2'.repeat(64)}";\n`,
        'images/atc-gateway/versions.env': `ATC_RELEASE=@zgeoff/atc@4.2.0\nATC_ASSET=atc-gateway-linux-x64\nATC_ASSET_SHA256=${'3'.repeat(64)}\nGATEWAY_IMAGE_TAG=4.2.0\n`,
      },
    }),
  ).toStrictEqual(new Error('SHA256SUMS has 0 atc-gateway-linux-x64 lines, want 1'));
});

test('it refuses a file with two version lines', () => {
  expect(
    planPinEdits({
      record: getRecord('atc'),
      version: '5.0.0',
      values: {
        sha256sums: `${'4'.repeat(64)}  atc-linux-x64\n${'5'.repeat(64)}  atc-gateway-linux-x64\n`,
      },
      files: {
        'images/agent/Dockerfile': `ARG ATC_VERSION=4.2.0\nARG ATC_VERSION=4.1.0\nARG ATC_SHA256=${'1'.repeat(64)}\n`,
        'nixos/packages/atc.nix': `  version = "4.2.0";\n  sha256 = "${'2'.repeat(64)}";\n`,
        'images/atc-gateway/versions.env': `ATC_RELEASE=@zgeoff/atc@4.2.0\nATC_ASSET=atc-gateway-linux-x64\nATC_ASSET_SHA256=${'3'.repeat(64)}\nGATEWAY_IMAGE_TAG=4.2.0\n`,
      },
    }),
  ).toStrictEqual(
    new Error(
      String.raw`images/agent/Dockerfile has 2 lines that match '^ARG ATC_VERSION=(?<version>\d+\.\d+\.\d+)$', want 1`,
    ),
  );
});

test('it refuses a checkout without a pin file', () => {
  expect(
    planPinEdits({
      record: getRecord('auto-mode'),
      version: '2.1.0',
      values: { tarballSum: '7'.repeat(64) },
      files: {},
    }),
  ).toStrictEqual(
    new Error(
      'images/agent/Dockerfile is missing: run this from the root of a zgeoff/cloud checkout',
    ),
  );
});

test('it refuses a version that is not a release version', () => {
  expect(
    planPinEdits({ record: getRecord('auto-mode'), version: 'v2.1.0', values: {}, files: {} }),
  ).toStrictEqual(new Error("not a release version: 'v2.1.0'"));
});

test('it pins an auto-mode release and its tarball sum', () => {
  const plan = planPinEdits({
    record: getRecord('auto-mode'),
    version: '2.1.0',
    values: { tarballSum: '7'.repeat(64) },
    files: {
      'images/agent/Dockerfile': `ARG AUTO_MODE_VERSION=2.0.0\nARG AUTO_MODE_SHA256=${'6'.repeat(64)}\nRUN true\n`,
    },
  });

  if (plan instanceof Error) {
    throw plan;
  }

  expect(plan.files).toStrictEqual({
    'images/agent/Dockerfile': `ARG AUTO_MODE_VERSION=2.1.0\nARG AUTO_MODE_SHA256=${'7'.repeat(64)}\nRUN true\n`,
  });
});

test('it leaves an auto-mode pin that already matches alone', () => {
  const plan = planPinEdits({
    record: getRecord('auto-mode'),
    version: '2.0.0',
    values: { tarballSum: '6'.repeat(64) },
    files: {
      'images/agent/Dockerfile': `ARG AUTO_MODE_VERSION=2.0.0\nARG AUTO_MODE_SHA256=${'6'.repeat(64)}\n`,
    },
  });

  expect(plan).toStrictEqual({ files: {}, notes: ['auto-mode already pins 2.0.0'], written: [] });
});

test('it refuses another tarball sum for the pinned auto-mode version', () => {
  expect(
    planPinEdits({
      record: getRecord('auto-mode'),
      version: '2.0.0',
      values: { tarballSum: '8'.repeat(64) },
      files: {
        'images/agent/Dockerfile': `ARG AUTO_MODE_VERSION=2.0.0\nARG AUTO_MODE_SHA256=${'6'.repeat(64)}\n`,
      },
    }),
  ).toStrictEqual(
    new Error(
      `auto-mode pins 2.0.0 with ${'6'.repeat(64)}, but the release lists ${'8'.repeat(64)}`,
    ),
  );
});

test('it pins an imp release in the flake input, the host image and both imp-base lines', () => {
  const plan = planPinEdits({
    record: getRecord('imp'),
    version: '2.4.0',
    values: {
      commit: 'abcdef0123456789abcdef0123456789abcdef01',
      digests: { 'imp-host': `sha256:${'c'.repeat(64)}`, 'imp-base': `sha256:${'d'.repeat(64)}` },
    },
    files: {
      'nixos/hosts/geoffcloud/configuration.nix': `    image = "ghcr.io/zgeoff/imp-host:2.3.0@sha256:${'a'.repeat(64)}";\n    impRegistryImage = "ghcr.io/zgeoff/imp-base:2.3.0@sha256:${'b'.repeat(64)}";\n`,
      'nixos/flake.nix': '    imp = {\n      url = "github:zgeoff/impz/94932a6b";\n    };\n',
      'images/agent/Dockerfile': `FROM ghcr.io/zgeoff/imp-base:2.3.0@sha256:${'b'.repeat(64)}\n`,
    },
  });

  if (plan instanceof Error) {
    throw plan;
  }

  expect([plan.files, plan.written.map((pin) => pin.id)]).toStrictEqual([
    {
      'nixos/hosts/geoffcloud/configuration.nix': `    image = "ghcr.io/zgeoff/imp-host:2.4.0@sha256:${'c'.repeat(64)}";\n    impRegistryImage = "ghcr.io/zgeoff/imp-base:2.4.0@sha256:${'d'.repeat(64)}";\n`,
      'nixos/flake.nix': '    imp = {\n      url = "github:zgeoff/impz/abcdef01";\n    };\n',
      'images/agent/Dockerfile': `FROM ghcr.io/zgeoff/imp-base:2.4.0@sha256:${'d'.repeat(64)}\n`,
    },
    ['imp-host', 'imp-base'],
  ]);
});

test('it keeps a newer imp-base and pins the host', () => {
  const plan = planPinEdits({
    record: getRecord('imp'),
    version: '2.4.0',
    values: {
      commit: 'abcdef0123456789abcdef0123456789abcdef01',
      digests: { 'imp-host': `sha256:${'c'.repeat(64)}`, 'imp-base': `sha256:${'d'.repeat(64)}` },
    },
    files: {
      'nixos/hosts/geoffcloud/configuration.nix': `    image = "ghcr.io/zgeoff/imp-host:2.3.0@sha256:${'a'.repeat(64)}";\n    impRegistryImage = "ghcr.io/zgeoff/imp-base:2.5.0@sha256:${'b'.repeat(64)}";\n`,
      'nixos/flake.nix': '      url = "github:zgeoff/impz/94932a6b";\n',
      'images/agent/Dockerfile': `FROM ghcr.io/zgeoff/imp-base:2.5.0@sha256:${'b'.repeat(64)}\n`,
    },
  });

  if (plan instanceof Error) {
    throw plan;
  }

  expect([Object.keys(plan.files), plan.written.map((pin) => pin.id)]).toStrictEqual([
    ['nixos/hosts/geoffcloud/configuration.nix', 'nixos/flake.nix'],
    ['imp-host'],
  ]);
});

test('it writes no imp-host line when the host already holds the release', () => {
  const plan = planPinEdits({
    record: getRecord('imp'),
    version: '2.4.0',
    values: {
      commit: 'abcdef0123456789abcdef0123456789abcdef01',
      digests: { 'imp-host': `sha256:${'c'.repeat(64)}`, 'imp-base': `sha256:${'d'.repeat(64)}` },
    },
    files: {
      'nixos/hosts/geoffcloud/configuration.nix': `    image = "ghcr.io/zgeoff/imp-host:2.4.0@sha256:${'c'.repeat(64)}";\n    impRegistryImage = "ghcr.io/zgeoff/imp-base:2.3.0@sha256:${'b'.repeat(64)}";\n`,
      'nixos/flake.nix': '      url = "github:zgeoff/impz/abcdef01";\n',
      'images/agent/Dockerfile': `FROM ghcr.io/zgeoff/imp-base:2.3.0@sha256:${'b'.repeat(64)}\n`,
    },
  });

  if (plan instanceof Error) {
    throw plan;
  }

  expect(plan.written.map((pin) => pin.id)).toStrictEqual(['imp-base']);
});

test('it refuses imp-base pins that disagree', () => {
  expect(
    planPinEdits({
      record: getRecord('imp'),
      version: '2.4.0',
      values: {
        commit: 'abcdef0123456789abcdef0123456789abcdef01',
        digests: { 'imp-host': `sha256:${'c'.repeat(64)}`, 'imp-base': `sha256:${'d'.repeat(64)}` },
      },
      files: {
        'nixos/hosts/geoffcloud/configuration.nix': `    image = "ghcr.io/zgeoff/imp-host:2.3.0@sha256:${'a'.repeat(64)}";\n    impRegistryImage = "ghcr.io/zgeoff/imp-base:2.2.0@sha256:${'b'.repeat(64)}";\n`,
        'nixos/flake.nix': '      url = "github:zgeoff/impz/94932a6b";\n',
        'images/agent/Dockerfile': `FROM ghcr.io/zgeoff/imp-base:2.3.0@sha256:${'b'.repeat(64)}\n`,
      },
    }),
  ).toStrictEqual(
    new Error('imp-base pins 2.3.0 in one line and 2.2.0 in another: pin both at one release'),
  );
});

test('it refuses an imp release pinned with another digest', () => {
  expect(
    planPinEdits({
      record: getRecord('imp'),
      version: '2.3.0',
      values: {
        commit: 'abcdef0123456789abcdef0123456789abcdef01',
        digests: { 'imp-host': `sha256:${'c'.repeat(64)}`, 'imp-base': `sha256:${'b'.repeat(64)}` },
      },
      files: {
        'nixos/hosts/geoffcloud/configuration.nix': `    image = "ghcr.io/zgeoff/imp-host:2.3.0@sha256:${'a'.repeat(64)}";\n    impRegistryImage = "ghcr.io/zgeoff/imp-base:2.3.0@sha256:${'b'.repeat(64)}";\n`,
        'nixos/flake.nix': '      url = "github:zgeoff/impz/94932a6b";\n',
        'images/agent/Dockerfile': `FROM ghcr.io/zgeoff/imp-base:2.3.0@sha256:${'b'.repeat(64)}\n`,
      },
    }),
  ).toStrictEqual(
    new Error(
      `imp-host pins 2.3.0 with sha256:${'a'.repeat(64)}, but the release lists sha256:${'c'.repeat(64)}`,
    ),
  );
});

test('it pins both nixie images and the contract package at the release and leaves the other images alone', () => {
  const plan = planPinEdits({
    record: getRecord('nixie'),
    version: '0.32.0',
    values: {
      digests: { nixie: `sha256:${'e'.repeat(64)}`, 'nixie-web': `sha256:${'f'.repeat(64)}` },
    },
    files: {
      'infra/Pulumi.prod.yaml': `config:\n  geoff-cloud:nixie:\n    image: ghcr.io/zgeoff/nixie:0.31.0@sha256:${'1'.repeat(64)}\n    webImage: ghcr.io/zgeoff/nixie-web:0.31.0@sha256:${'2'.repeat(64)}\n    backupImage: ghcr.io/zgeoff/backup:1.0.0@sha256:${'3'.repeat(64)}\n`,
      'package.json':
        '{\n  "devDependencies": {\n    "@heynixie/contract": "0.31.0",\n    "@impz/client": "6.1.0"\n  }\n}\n',
    },
  });

  if (plan instanceof Error) {
    throw plan;
  }

  expect(plan.files).toStrictEqual({
    'infra/Pulumi.prod.yaml': `config:\n  geoff-cloud:nixie:\n    image: ghcr.io/zgeoff/nixie:0.32.0@sha256:${'e'.repeat(64)}\n    webImage: ghcr.io/zgeoff/nixie-web:0.32.0@sha256:${'f'.repeat(64)}\n    backupImage: ghcr.io/zgeoff/backup:1.0.0@sha256:${'3'.repeat(64)}\n`,
    'package.json':
      '{\n  "devDependencies": {\n    "@heynixie/contract": "0.32.0",\n    "@impz/client": "6.1.0"\n  }\n}\n',
  });
});

test('it refuses a nixie release whose notes list no web image', () => {
  expect(
    planPinEdits({
      record: getRecord('nixie'),
      version: '0.32.0',
      values: { digests: { nixie: `sha256:${'e'.repeat(64)}` } },
      files: {
        'infra/Pulumi.prod.yaml': `    image: ghcr.io/zgeoff/nixie:0.31.0@sha256:${'1'.repeat(64)}\n    webImage: ghcr.io/zgeoff/nixie-web:0.31.0@sha256:${'2'.repeat(64)}\n`,
      },
    }),
  ).toStrictEqual(new Error('the release lists no nixie-web digest'));
});

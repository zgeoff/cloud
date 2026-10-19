import { expect, test } from 'bun:test';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { getReleaseRecord } from '../test-utils/get-release-record.ts';
import { collectPinFiles } from './collect-pin-files.ts';
import { findPinnedVersions } from './find-pinned-versions.ts';
import { releaseRegistry } from './release-registry.ts';

test('it finds the version of each pin in the record order', () => {
  expect(
    findPinnedVersions(getReleaseRecord('atc'), {
      'images/agent/Dockerfile': 'FROM example\nARG ATC_VERSION=4.3.0\n',
      'nixos/packages/atc.nix': '  version = "2.26.2";\n',
      'images/atc-gateway/versions.env': 'ATC_RELEASE=@zgeoff/atc@4.1.0\n',
    }),
  ).toStrictEqual(['4.3.0', '2.26.2', '4.1.0']);
});

test('it reads a pin version from its first line that holds one', () => {
  expect(
    findPinnedVersions(getReleaseRecord('imp'), {
      'nixos/hosts/geoffcloud/configuration.nix': `    image = "ghcr.io/zgeoff/imp-host:1.0.0@sha256:${'1'.repeat(64)}";\n    impRegistryImage = "ghcr.io/zgeoff/imp-base:0.32.0@sha256:${'2'.repeat(64)}";\n`,
      'images/agent/Dockerfile': `FROM ghcr.io/zgeoff/imp-base:0.33.0@sha256:${'2'.repeat(64)}\n`,
    }),
  ).toStrictEqual(['1.0.0', '0.33.0']);
});

test('it fails on a pin line that no line of its file matches', () => {
  expect(
    findPinnedVersions(getReleaseRecord('auto-mode'), {
      'images/agent/Dockerfile': 'ARG ATC_VERSION=4.3.0\n',
    }),
  ).toStrictEqual(
    new Error(
      String.raw`images/agent/Dockerfile has 0 lines that match '^ARG AUTO_MODE_VERSION=(?<version>\d+\.\d+\.\d+)$', want 1`,
    ),
  );
});

test('it fails on a pin file the checkout lacks', () => {
  expect(findPinnedVersions(getReleaseRecord('auto-mode'), {})).toStrictEqual(
    new Error(
      'images/agent/Dockerfile is missing: run this from the root of a zgeoff/cloud checkout',
    ),
  );
});

const checkedRecords = releaseRegistry.filter(
  (record) => record.source.kind !== 'published-images',
);

test.each(checkedRecords.map((record) => [record.name, record] as const))(
  'it finds a release version for every %s pin in the real checkout',
  async (_name, record) => {
    const checkout = join(import.meta.dir, '../..');

    const entries = await Promise.all(
      collectPinFiles(record).map(
        async (path) => [path, await readFile(join(checkout, path), 'utf8')] as const,
      ),
    );

    const versions = findPinnedVersions(record, Object.fromEntries(entries));

    if (versions instanceof Error) {
      throw versions;
    }

    expect(versions).toHaveLength(record.pins.length);
    expect(versions).toSatisfyAll((version: string) => /^\d+\.\d+\.\d+$/u.test(version));
  },
);

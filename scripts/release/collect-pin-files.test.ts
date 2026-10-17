import { expect, test } from 'bun:test';
import { collectPinFiles } from './collect-pin-files.ts';
import { findReleaseRecord } from './find-release-record.ts';

test.each([
  [
    'release-check/atc',
    [
      'images/agent/Dockerfile',
      'images/atc-gateway/versions.env',
      'nixos/packages/atc.nix',
      'scripts/release/release-pins.json',
    ],
  ],
  [
    'release-check/imp',
    [
      'images/agent/Dockerfile',
      'nixos/flake.lock',
      'nixos/flake.nix',
      'nixos/hosts/geoffcloud/configuration.nix',
      'scripts/release/release-pins.json',
    ],
  ],
  [
    'release-check/nixie',
    [
      'infra/Pulumi.prod.yaml',
      'scripts/nixie-api/openapi.d.ts',
      'scripts/nixie-api/openapi.json',
      'scripts/release/release-pins.json',
    ],
  ],
  ['release-check/auto-mode', ['images/agent/Dockerfile', 'scripts/release/release-pins.json']],
])('it lists the files that a bump from %s writes', (branch: string, files: readonly string[]) => {
  const record = findReleaseRecord(branch);

  if (record === undefined) {
    throw new Error(`no record for ${branch}`);
  }

  expect(collectPinFiles(record)).toStrictEqual(files);
});

test('it lists a file once and its lock file beside its lines', () => {
  expect(
    collectPinFiles({
      name: 'example',
      repo: 'zgeoff/example',
      tagPrefix: 'v',
      source: { kind: 'sha256sums' },
      pins: [
        {
          id: 'one',
          title: 'one',
          lines: [
            {
              file: 'b/pins.txt',
              pattern: '^ONE=(?<version>.*)$',
              parts: { version: { kind: 'version' } },
            },
            {
              file: 'b/pins.txt',
              pattern: '^ONE_SUM=(?<sum>.*)$',
              parts: { sum: { kind: 'tarball-sum' } },
            },
          ],
          lock: { kind: 'nix-flake-lock', flake: 'a', input: 'one', lockFile: 'a/flake.lock' },
        },
      ],
      rollout: 'nothing',
    }),
  ).toStrictEqual(['a/flake.lock', 'b/pins.txt', 'scripts/release/release-pins.json']);
});

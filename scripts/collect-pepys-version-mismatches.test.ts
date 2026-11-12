import { expect, test } from 'bun:test';
import { join } from 'node:path';
import { collectPepysVersionMismatches } from './collect-pepys-version-mismatches.ts';

function setupTest() {
  return { versionsEnv: 'PEPYS_RELEASE=v0.4.0\nPEPYS_HOST_ASSET=pepys-host-linux-x64\n' };
}

test('it finds nothing when every @pepys/* package carries the pinned release', () => {
  const ctx = setupTest();

  expect(
    collectPepysVersionMismatches(ctx.versionsEnv, {
      dependencies: { '@pepys/kit': '0.4.0', '@pepys/ingest': '0.4.0', zod: '4.6.7' },
    }),
  ).toStrictEqual([]);
});

test('it names each @pepys/* package that a host bump left behind', () => {
  const ctx = setupTest();

  expect(
    collectPepysVersionMismatches(ctx.versionsEnv, {
      dependencies: { '@pepys/kit': '0.3.2', '@pepys/ingest': '0.4.0', '@pepys/api': '0.3.2' },
    }),
  ).toStrictEqual([
    'deploy/pepys/package.json pins @pepys/kit at 0.3.2, but images/pepys/versions.env pins the release v0.4.0',
    'deploy/pepys/package.json pins @pepys/api at 0.3.2, but images/pepys/versions.env pins the release v0.4.0',
  ]);
});

test('it fails a versions file without a release pin, and a manifest without a @pepys/* package', () => {
  const ctx = setupTest();

  expect(
    collectPepysVersionMismatches('PEPYS_RELEASE=latest\n', {
      dependencies: { '@pepys/kit': '0.4.0' },
    }),
  ).toStrictEqual(['images/pepys/versions.env has no PEPYS_RELEASE=v<major>.<minor>.<patch> line']);

  expect(
    collectPepysVersionMismatches(ctx.versionsEnv, { dependencies: { zod: '4.6.7' } }),
  ).toStrictEqual(['deploy/pepys/package.json depends on no @pepys/* package']);
});

test('it finds the repo pins of the host and the packages at one release', async () => {
  const root = join(import.meta.dir, '..');

  const pins = await Bun.file(join(root, 'images/pepys/versions.env')).text();
  const manifest: unknown = await Bun.file(join(root, 'deploy/pepys/package.json')).json();

  expect(collectPepysVersionMismatches(pins, manifest)).toStrictEqual([]);
});

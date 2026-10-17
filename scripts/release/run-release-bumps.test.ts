import { expect, mock, test } from 'bun:test';
import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { buildRealProgramHandler } from '../test-utils/build-real-program-handler.ts';
import { buildStubReleaseGH } from '../test-utils/build-stub-release-gh.ts';
import { buildStubRunner } from '../test-utils/build-stub-runner.ts';
import { createCloudCheckout } from '../test-utils/create-cloud-checkout.ts';
import { runReleaseBumps } from './run-release-bumps.ts';

function setupTest() {
  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  return { printOut, printErr };
}

test('it runs each bump in its own group from a clean tree', async () => {
  const ctx = setupTest();

  const checkout = await createCloudCheckout({
    'scripts/release/release-pins.json': `${JSON.stringify(
      {
        'atc-agent': { version: '4.3.0', sum: '4'.repeat(64) },
        'atc-daemon': { version: '4.3.0', sum: '4'.repeat(64) },
        'atc-gateway': { version: '4.3.0', sum: '5'.repeat(64), tag: '4.3.0' },
        nixie: { version: '0.7.0', digest: `sha256:${'a'.repeat(64)}` },
        'nixie-web': { version: '0.7.0', digest: `sha256:${'b'.repeat(64)}` },
      },
      null,
      2,
    )}\n`,
    'images/agent/Dockerfile': `ARG ATC_VERSION=4.3.0\nARG ATC_SHA256=${'4'.repeat(64)}\n`,
    'nixos/packages/atc.nix': `  version = "4.3.0";\n  sha256 = "${'4'.repeat(64)}";\n`,
    'images/atc-gateway/versions.env': `ATC_RELEASE=@zgeoff/atc@4.3.0\nATC_ASSET=atc-gateway-linux-x64\nATC_ASSET_SHA256=${'5'.repeat(64)}\nGATEWAY_IMAGE_TAG=4.3.0\n`,
    'infra/Pulumi.prod.yaml': `    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:${'a'.repeat(64)}\n    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:${'b'.repeat(64)}\n`,
  });

  await Promise.all([
    writeFile(join(checkout.clone, 'images/agent/Dockerfile'), 'ARG ATC_VERSION=9.9.9\n'),
    writeFile(join(checkout.clone, 'left-behind.txt'), 'a file a failed pin left\n'),
  ]);

  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: {
        'zgeoff/atc': [
          {
            tag: '@zgeoff/atc@4.3.0',
            assets: {
              SHA256SUMS: `${'4'.repeat(64)}  atc-linux-x64\n${'5'.repeat(64)}  atc-gateway-linux-x64\n`,
            },
          },
        ],
        'zgeoff/nixie': [
          {
            tag: 'v0.7.0',
            notes: `## Migrations\n\nThis release adds no migration since v0.6.2.\n\n## Images\n\n- \`ghcr.io/zgeoff/nixie@sha256:${'a'.repeat(64)}\`\n- \`ghcr.io/zgeoff/nixie-web@sha256:${'b'.repeat(64)}\`\n`,
          },
          {
            tag: 'v0.6.2',
            notes: `## Images\n\n- \`ghcr.io/zgeoff/nixie@sha256:${'c'.repeat(64)}\`\n`,
          },
        ],
      },
    }),
    buildRealProgramHandler(['git'], checkout.env),
  );

  const status = await runReleaseBumps({
    cwd: checkout.clone,
    env: { ...checkout.env, BUMPS: 'atc 4.3.0 4.3.0 4.2.0 4.3.0\nnixie 0.7.0 0.6.2 0.6.2\n' },
    run: stub.run,
    ...ctx,
  });

  const tree = await checkout.git(['-C', checkout.clone, 'status', '--porcelain']);

  expect(status).toBe(0);

  expect(ctx.printOut.mock.calls).toStrictEqual([
    ['::group::atc 4.3.0\n'],
    [
      'atc-agent already pins 4.3.0\natc-daemon already pins 4.3.0\natc-gateway already pins 4.3.0\n',
    ],
    ['::endgroup::\n'],
    ['::group::nixie 0.7.0\n'],
    ['nixie already pins 0.7.0\nnixie-web already pins 0.7.0\n'],
    ['::endgroup::\n'],
  ]);

  expect(ctx.printErr.mock.calls).toStrictEqual([]);
  expect(tree).toBe('');
});

test('it runs every bump after a failed one then fails naming it', async () => {
  const ctx = setupTest();

  const checkout = await createCloudCheckout({
    'scripts/release/release-pins.json': `${JSON.stringify(
      {
        nixie: { version: '0.7.0', digest: `sha256:${'a'.repeat(64)}` },
        'nixie-web': { version: '0.7.0', digest: `sha256:${'b'.repeat(64)}` },
      },
      null,
      2,
    )}\n`,
    'infra/Pulumi.prod.yaml': `    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:${'a'.repeat(64)}\n    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:${'b'.repeat(64)}\n`,
  });

  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: {
        'zgeoff/atc': [{ tag: '@zgeoff/atc@4.3.0' }],
        'zgeoff/nixie': [
          {
            tag: 'v0.7.0',
            notes: `## Migrations\n\nThis release adds no migration since v0.6.2.\n\n## Images\n\n- \`ghcr.io/zgeoff/nixie@sha256:${'a'.repeat(64)}\`\n- \`ghcr.io/zgeoff/nixie-web@sha256:${'b'.repeat(64)}\`\n`,
          },
          {
            tag: 'v0.6.2',
            notes: `## Images\n\n- \`ghcr.io/zgeoff/nixie@sha256:${'c'.repeat(64)}\`\n`,
          },
        ],
      },
    }),
    buildRealProgramHandler(['git'], checkout.env),
  );

  const status = await runReleaseBumps({
    cwd: checkout.clone,
    env: { ...checkout.env, BUMPS: 'atc 4.3.0 4.3.0 4.2.0 4.3.0\nnixie 0.7.0 0.6.2 0.6.2\n' },
    run: stub.run,
    ...ctx,
  });

  expect(status).toBe(1);

  expect(ctx.printOut.mock.calls).toStrictEqual([
    ['::group::atc 4.3.0\n'],
    ['::error::the atc bump failed\n'],
    ['::endgroup::\n'],
    ['::group::nixie 0.7.0\n'],
    ['nixie already pins 0.7.0\nnixie-web already pins 0.7.0\n'],
    ['::endgroup::\n'],
  ]);

  expect(ctx.printErr.mock.calls).toStrictEqual([['release not found\n']]);
});

test('it fails without bumps', async () => {
  const ctx = setupTest();
  const stub = buildStubRunner();

  const status = await runReleaseBumps({
    cwd: '/nonexistent/clone',
    env: {},
    run: stub.run,
    ...ctx,
  });

  expect(status).toBe(2);
  expect(ctx.printOut.mock.calls).toStrictEqual([]);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ["BUMPS must be set, as the check job's output sets it\n"],
  ]);

  expect(stub.calls).toStrictEqual([]);
});

import { expect, mock, test } from 'bun:test';
import { buildStubReleaseGH } from '../test-utils/build-stub-release-gh.ts';
import { buildStubRunner } from '../test-utils/build-stub-runner.ts';
import { createCloudCheckout } from '../test-utils/create-cloud-checkout.ts';
import { runReleasePin } from './run-release-pin.ts';

function setupTest() {
  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  return { printOut, printErr };
}

test('it pins a release in the checkout it runs from', async () => {
  const ctx = setupTest();

  const checkout = await createCloudCheckout({
    'images/agent/Dockerfile': `ARG ATC_VERSION=4.2.0\nARG ATC_SHA256=${'1'.repeat(64)}\n`,
    'nixos/packages/atc.nix': `  version = "4.2.0";\n  sha256 = "${'1'.repeat(64)}";\n`,
    'images/atc-gateway/versions.env': `ATC_RELEASE=@zgeoff/atc@4.2.0\nATC_ASSET=atc-gateway-linux-x64\nATC_ASSET_SHA256=${'3'.repeat(64)}\nGATEWAY_IMAGE_TAG=4.2.0\n`,
  });

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
      },
    }),
  );

  const status = await runReleasePin({ cwd: checkout.clone, env: {}, run: stub.run, ...ctx }, [
    'atc',
    '4.3.0',
  ]);

  const changed = await checkout.git(['-C', checkout.clone, 'diff', '-U0', '--no-prefix']);

  expect(status).toBe(0);

  expect(ctx.printOut.mock.calls).toStrictEqual([
    ['pinned atc-agent 4.3.0\npinned atc-daemon 4.3.0\npinned atc-gateway 4.3.0\n'],
  ]);

  expect(ctx.printErr.mock.calls).toStrictEqual([]);

  expect(
    changed
      .split('\n')
      .filter((line) => /^[+-][^+-]/u.test(line))
      .join('\n'),
  ).toBe(
    `-ARG ATC_VERSION=4.2.0\n-ARG ATC_SHA256=${'1'.repeat(64)}\n+ARG ATC_VERSION=4.3.0\n+ARG ATC_SHA256=${'4'.repeat(64)}\n-ATC_RELEASE=@zgeoff/atc@4.2.0\n+ATC_RELEASE=@zgeoff/atc@4.3.0\n-ATC_ASSET_SHA256=${'3'.repeat(64)}\n-GATEWAY_IMAGE_TAG=4.2.0\n+ATC_ASSET_SHA256=${'5'.repeat(64)}\n+GATEWAY_IMAGE_TAG=4.3.0\n-  version = "4.2.0";\n-  sha256 = "${'1'.repeat(64)}";\n+  version = "4.3.0";\n+  sha256 = "${'4'.repeat(64)}";`,
  );
});

test('it fails with the release error and changes no pin', async () => {
  const ctx = setupTest();

  const checkout = await createCloudCheckout({
    'images/agent/Dockerfile': `ARG ATC_VERSION=4.2.0\nARG ATC_SHA256=${'1'.repeat(64)}\n`,
    'nixos/packages/atc.nix': `  version = "4.2.0";\n  sha256 = "${'1'.repeat(64)}";\n`,
    'images/atc-gateway/versions.env': `ATC_RELEASE=@zgeoff/atc@4.2.0\nATC_ASSET=atc-gateway-linux-x64\nATC_ASSET_SHA256=${'3'.repeat(64)}\nGATEWAY_IMAGE_TAG=4.2.0\n`,
  });

  const stub = buildStubRunner(
    buildStubReleaseGH({ releases: { 'zgeoff/atc': [{ tag: '@zgeoff/atc@4.3.0' }] } }),
  );

  const status = await runReleasePin({ cwd: checkout.clone, env: {}, run: stub.run, ...ctx }, [
    'atc',
    '4.3.0',
  ]);

  const changed = await checkout.git(['-C', checkout.clone, 'status', '--porcelain']);

  expect(status).toBe(1);
  expect(ctx.printOut.mock.calls).toStrictEqual([]);
  expect(ctx.printErr.mock.calls).toStrictEqual([['release not found\n']]);
  expect(changed).toBe('');
});

test('it prints its usage for a dependency the registry lacks', async () => {
  const ctx = setupTest();
  const stub = buildStubRunner();

  const status = await runReleasePin(
    { cwd: '/nonexistent/checkout', env: {}, run: stub.run, ...ctx },
    ['atc-gateway', '4.3.0'],
  );

  expect(status).toBe(2);
  expect(ctx.printOut.mock.calls).toStrictEqual([]);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['usage: run-release-pin.ts <atc|imp|nixie|auto-mode> <version>\n'],
  ]);

  expect(stub.calls).toStrictEqual([]);
});

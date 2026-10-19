import { expect, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildStubReleaseGH } from '../test-utils/build-stub-release-gh.ts';
import { buildStubRunner } from '../test-utils/build-stub-runner.ts';
import { readReleaseBumps } from './read-release-bumps.ts';

async function setupTest() {
  const root = await mkdtemp(join(tmpdir(), 'read-release-bumps-'));

  onTestFinished(() => rm(root, { recursive: true, force: true }));

  await Promise.all(
    ['images/agent', 'nixos/packages', 'nixos/hosts/geoffcloud', 'images/atc-gateway', 'infra'].map(
      (directory) => mkdir(join(root, directory), { recursive: true }),
    ),
  );

  return { root };
}

test('it finds nothing when every pin holds its newest release', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'images/agent/Dockerfile'),
    `FROM ghcr.io/zgeoff/imp-base:1.0.1@sha256:${'2'.repeat(64)}\nARG ATC_VERSION=4.3.0\nARG AUTO_MODE_VERSION=0.19.3\n`,
  );

  await writeFile(join(ctx.root, 'nixos/packages/atc.nix'), '  version = "4.3.0";\n');

  await writeFile(
    join(ctx.root, 'images/atc-gateway/versions.env'),
    'ATC_RELEASE=@zgeoff/atc@4.3.0\n',
  );

  await writeFile(
    join(ctx.root, 'nixos/hosts/geoffcloud/configuration.nix'),
    `    image = "ghcr.io/zgeoff/imp-host:1.0.1@sha256:${'1'.repeat(64)}";\n`,
  );

  await writeFile(
    join(ctx.root, 'infra/Pulumi.prod.yaml'),
    `    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:${'3'.repeat(64)}\n    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:${'4'.repeat(64)}\n`,
  );

  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: {
        'zgeoff/atc': [{ tag: '@zgeoff/atc@4.3.0' }],
        'zgeoff/impz': [{ tag: 'v1.0.1' }],
        'zgeoff/nixie': [{ tag: 'v0.7.0' }],
        'zgeoff/auto-mode': [{ tag: 'auto-mode-v0.19.3' }],
      },
    }),
  );

  const bumps = await readReleaseBumps(ctx.root, stub.run);

  expect(bumps).toStrictEqual([]);

  expect(stub.calls.map((call) => call.argv.slice(0, 5))).toStrictEqual([
    ['gh', 'release', 'list', '-R', 'zgeoff/atc'],
    ['gh', 'release', 'list', '-R', 'zgeoff/impz'],
    ['gh', 'release', 'list', '-R', 'zgeoff/nixie'],
    ['gh', 'release', 'list', '-R', 'zgeoff/auto-mode'],
  ]);
});

test('it finds the atc line with every pinned version when one pin is older', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'images/agent/Dockerfile'),
    `FROM ghcr.io/zgeoff/imp-base:1.0.1@sha256:${'2'.repeat(64)}\nARG ATC_VERSION=4.3.0\nARG AUTO_MODE_VERSION=0.19.3\n`,
  );

  await writeFile(join(ctx.root, 'nixos/packages/atc.nix'), '  version = "2.26.2";\n');

  await writeFile(
    join(ctx.root, 'images/atc-gateway/versions.env'),
    'ATC_RELEASE=@zgeoff/atc@4.3.0\n',
  );

  await writeFile(
    join(ctx.root, 'nixos/hosts/geoffcloud/configuration.nix'),
    `    image = "ghcr.io/zgeoff/imp-host:1.0.1@sha256:${'1'.repeat(64)}";\n`,
  );

  await writeFile(
    join(ctx.root, 'infra/Pulumi.prod.yaml'),
    `    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:${'3'.repeat(64)}\n    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:${'4'.repeat(64)}\n`,
  );

  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: {
        'zgeoff/atc': [{ tag: '@zgeoff/atc@4.3.0' }],
        'zgeoff/impz': [{ tag: 'v1.0.1' }],
        'zgeoff/nixie': [{ tag: 'v0.7.0' }],
        'zgeoff/auto-mode': [{ tag: 'auto-mode-v0.19.3' }],
      },
    }),
  );

  const bumps = await readReleaseBumps(ctx.root, stub.run);

  expect(bumps).toStrictEqual(['atc 4.3.0 4.3.0 2.26.2 4.3.0']);
});

test('it finds the imp and nixie lines when their pins are older', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'images/agent/Dockerfile'),
    `FROM ghcr.io/zgeoff/imp-base:0.33.0@sha256:${'2'.repeat(64)}\nARG ATC_VERSION=4.3.0\nARG AUTO_MODE_VERSION=0.19.3\n`,
  );

  await writeFile(join(ctx.root, 'nixos/packages/atc.nix'), '  version = "4.3.0";\n');

  await writeFile(
    join(ctx.root, 'images/atc-gateway/versions.env'),
    'ATC_RELEASE=@zgeoff/atc@4.3.0\n',
  );

  await writeFile(
    join(ctx.root, 'nixos/hosts/geoffcloud/configuration.nix'),
    `    image = "ghcr.io/zgeoff/imp-host:1.0.0@sha256:${'1'.repeat(64)}";\n`,
  );

  await writeFile(
    join(ctx.root, 'infra/Pulumi.prod.yaml'),
    `    image: ghcr.io/zgeoff/nixie:0.6.2@sha256:${'3'.repeat(64)}\n    webImage: ghcr.io/zgeoff/nixie-web:0.6.2@sha256:${'4'.repeat(64)}\n`,
  );

  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: {
        'zgeoff/atc': [{ tag: '@zgeoff/atc@4.3.0' }],
        'zgeoff/impz': [{ tag: 'v1.0.1' }],
        'zgeoff/nixie': [{ tag: 'v0.7.0' }],
        'zgeoff/auto-mode': [{ tag: 'auto-mode-v0.19.3' }],
      },
    }),
  );

  const bumps = await readReleaseBumps(ctx.root, stub.run);

  expect(bumps).toStrictEqual(['imp 1.0.1 1.0.0 0.33.0', 'nixie 0.7.0 0.6.2 0.6.2']);
});

test('it finds the auto-mode line when the agent image pin is older', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'images/agent/Dockerfile'),
    `FROM ghcr.io/zgeoff/imp-base:1.0.1@sha256:${'2'.repeat(64)}\nARG ATC_VERSION=4.3.0\nARG AUTO_MODE_VERSION=0.17.0\n`,
  );

  await writeFile(join(ctx.root, 'nixos/packages/atc.nix'), '  version = "4.3.0";\n');

  await writeFile(
    join(ctx.root, 'images/atc-gateway/versions.env'),
    'ATC_RELEASE=@zgeoff/atc@4.3.0\n',
  );

  await writeFile(
    join(ctx.root, 'nixos/hosts/geoffcloud/configuration.nix'),
    `    image = "ghcr.io/zgeoff/imp-host:1.0.1@sha256:${'1'.repeat(64)}";\n`,
  );

  await writeFile(
    join(ctx.root, 'infra/Pulumi.prod.yaml'),
    `    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:${'3'.repeat(64)}\n    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:${'4'.repeat(64)}\n`,
  );

  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: {
        'zgeoff/atc': [{ tag: '@zgeoff/atc@4.3.0' }],
        'zgeoff/impz': [{ tag: 'v1.0.1' }],
        'zgeoff/nixie': [{ tag: 'v0.7.0' }],
        'zgeoff/auto-mode': [{ tag: 'auto-mode-v0.19.3' }],
      },
    }),
  );

  const bumps = await readReleaseBumps(ctx.root, stub.run);

  expect(bumps).toStrictEqual(['auto-mode 0.19.3 0.17.0']);
});

test('it takes the highest version among the tags of the dependency own form', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'images/agent/Dockerfile'),
    `FROM ghcr.io/zgeoff/imp-base:1.0.1@sha256:${'2'.repeat(64)}\nARG ATC_VERSION=4.2.0\nARG AUTO_MODE_VERSION=0.19.3\n`,
  );

  await writeFile(join(ctx.root, 'nixos/packages/atc.nix'), '  version = "4.2.0";\n');

  await writeFile(
    join(ctx.root, 'images/atc-gateway/versions.env'),
    'ATC_RELEASE=@zgeoff/atc@4.2.0\n',
  );

  await writeFile(
    join(ctx.root, 'nixos/hosts/geoffcloud/configuration.nix'),
    `    image = "ghcr.io/zgeoff/imp-host:1.0.1@sha256:${'1'.repeat(64)}";\n`,
  );

  await writeFile(
    join(ctx.root, 'infra/Pulumi.prod.yaml'),
    `    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:${'3'.repeat(64)}\n    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:${'4'.repeat(64)}\n`,
  );

  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: {
        'zgeoff/atc': [
          { tag: '@zgeoff/atc-client@9.0.0' },
          { tag: '@zgeoff/atc@4.9.0' },
          { tag: '@zgeoff/atc@4.10.0' },
          { tag: '@zgeoff/atc@4.3.0' },
        ],
        'zgeoff/impz': [{ tag: 'v1.2.3-rc.1' }, { tag: 'v1.0.1' }],
        'zgeoff/nixie': [{ tag: 'v0.7.0' }],
        'zgeoff/auto-mode': [{ tag: 'auto-mode-v0.19.3' }],
      },
    }),
  );

  const bumps = await readReleaseBumps(ctx.root, stub.run);

  expect(bumps).toStrictEqual(['atc 4.10.0 4.2.0 4.2.0 4.2.0']);
});

test('it finds nothing for a pin newer than the newest release', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'images/agent/Dockerfile'),
    `FROM ghcr.io/zgeoff/imp-base:1.0.1@sha256:${'2'.repeat(64)}\nARG ATC_VERSION=4.4.0\nARG AUTO_MODE_VERSION=0.19.3\n`,
  );

  await writeFile(join(ctx.root, 'nixos/packages/atc.nix'), '  version = "4.3.0";\n');

  await writeFile(
    join(ctx.root, 'images/atc-gateway/versions.env'),
    'ATC_RELEASE=@zgeoff/atc@4.3.0\n',
  );

  await writeFile(
    join(ctx.root, 'nixos/hosts/geoffcloud/configuration.nix'),
    `    image = "ghcr.io/zgeoff/imp-host:1.0.1@sha256:${'1'.repeat(64)}";\n`,
  );

  await writeFile(
    join(ctx.root, 'infra/Pulumi.prod.yaml'),
    `    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:${'3'.repeat(64)}\n    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:${'4'.repeat(64)}\n`,
  );

  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: {
        'zgeoff/atc': [{ tag: '@zgeoff/atc@4.3.0' }],
        'zgeoff/impz': [{ tag: 'v1.0.1' }],
        'zgeoff/nixie': [{ tag: 'v0.7.0' }],
        'zgeoff/auto-mode': [{ tag: 'auto-mode-v0.19.3' }],
      },
    }),
  );

  const bumps = await readReleaseBumps(ctx.root, stub.run);

  expect(bumps).toStrictEqual([]);
});

test('it fails on a missing pin before it reads a release', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'images/agent/Dockerfile'),
    `FROM ghcr.io/zgeoff/imp-base:1.0.1@sha256:${'2'.repeat(64)}\n`,
  );

  await writeFile(join(ctx.root, 'nixos/packages/atc.nix'), '  version = "4.3.0";\n');

  await writeFile(
    join(ctx.root, 'images/atc-gateway/versions.env'),
    'ATC_RELEASE=@zgeoff/atc@4.3.0\n',
  );

  await writeFile(
    join(ctx.root, 'nixos/hosts/geoffcloud/configuration.nix'),
    `    image = "ghcr.io/zgeoff/imp-host:1.0.1@sha256:${'1'.repeat(64)}";\n`,
  );

  await writeFile(
    join(ctx.root, 'infra/Pulumi.prod.yaml'),
    `    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:${'3'.repeat(64)}\n    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:${'4'.repeat(64)}\n`,
  );

  const stub = buildStubRunner(buildStubReleaseGH({}));

  const bumps = await readReleaseBumps(ctx.root, stub.run);

  expect(bumps).toStrictEqual(
    new Error(
      String.raw`images/agent/Dockerfile has 0 lines that match '^ARG ATC_VERSION=(?<version>\d+\.\d+\.\d+)$', want 1`,
    ),
  );

  expect(stub.calls).toStrictEqual([]);
});

test('it fails on a doubled pin', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'images/agent/Dockerfile'),
    `FROM ghcr.io/zgeoff/imp-base:1.0.1@sha256:${'2'.repeat(64)}\nARG ATC_VERSION=4.3.0\nARG AUTO_MODE_VERSION=0.19.3\n`,
  );

  await writeFile(join(ctx.root, 'nixos/packages/atc.nix'), '  version = "4.3.0";\n');

  await writeFile(
    join(ctx.root, 'images/atc-gateway/versions.env'),
    'ATC_RELEASE=@zgeoff/atc@4.3.0\n',
  );

  await writeFile(
    join(ctx.root, 'nixos/hosts/geoffcloud/configuration.nix'),
    `    image = "ghcr.io/zgeoff/imp-host:1.0.1@sha256:${'1'.repeat(64)}";\n`,
  );

  await writeFile(
    join(ctx.root, 'infra/Pulumi.prod.yaml'),
    `    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:${'3'.repeat(64)}\n    image: ghcr.io/zgeoff/nixie:0.6.2@sha256:${'5'.repeat(64)}\n    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:${'4'.repeat(64)}\n`,
  );

  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: {
        'zgeoff/atc': [{ tag: '@zgeoff/atc@4.3.0' }],
        'zgeoff/impz': [{ tag: 'v1.0.1' }],
      },
    }),
  );

  const bumps = await readReleaseBumps(ctx.root, stub.run);

  expect(bumps).toStrictEqual(
    new Error(
      String.raw`infra/Pulumi.prod.yaml has 2 lines that match '^ +image: ghcr\.io\/zgeoff\/nixie:(?<version>\d+\.\d+\.\d+)@(?<digest>sha256:[0-9a-f]{64})$', want 1`,
    ),
  );

  expect(stub.calls).toStrictEqual([]);
});

test('it fails when a repository has no release of its form', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'images/agent/Dockerfile'),
    `FROM ghcr.io/zgeoff/imp-base:1.0.1@sha256:${'2'.repeat(64)}\nARG ATC_VERSION=4.3.0\nARG AUTO_MODE_VERSION=0.19.3\n`,
  );

  await writeFile(join(ctx.root, 'nixos/packages/atc.nix'), '  version = "4.3.0";\n');

  await writeFile(
    join(ctx.root, 'images/atc-gateway/versions.env'),
    'ATC_RELEASE=@zgeoff/atc@4.3.0\n',
  );

  await writeFile(
    join(ctx.root, 'nixos/hosts/geoffcloud/configuration.nix'),
    `    image = "ghcr.io/zgeoff/imp-host:1.0.1@sha256:${'1'.repeat(64)}";\n`,
  );

  await writeFile(
    join(ctx.root, 'infra/Pulumi.prod.yaml'),
    `    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:${'3'.repeat(64)}\n    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:${'4'.repeat(64)}\n`,
  );

  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: {
        'zgeoff/atc': [{ tag: '@zgeoff/atc@4.3.0' }],
        'zgeoff/impz': [{ tag: 'v1.2.3-rc.1' }],
      },
    }),
  );

  const bumps = await readReleaseBumps(ctx.root, stub.run);

  expect(bumps).toStrictEqual(new Error('zgeoff/impz has no release tagged vX.Y.Z'));
});

test('it gives the gh error when a release list fails', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'images/agent/Dockerfile'),
    `FROM ghcr.io/zgeoff/imp-base:1.0.1@sha256:${'2'.repeat(64)}\nARG ATC_VERSION=4.3.0\nARG AUTO_MODE_VERSION=0.19.3\n`,
  );

  await writeFile(join(ctx.root, 'nixos/packages/atc.nix'), '  version = "4.3.0";\n');

  await writeFile(
    join(ctx.root, 'images/atc-gateway/versions.env'),
    'ATC_RELEASE=@zgeoff/atc@4.3.0\n',
  );

  await writeFile(
    join(ctx.root, 'nixos/hosts/geoffcloud/configuration.nix'),
    `    image = "ghcr.io/zgeoff/imp-host:1.0.1@sha256:${'1'.repeat(64)}";\n`,
  );

  await writeFile(
    join(ctx.root, 'infra/Pulumi.prod.yaml'),
    `    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:${'3'.repeat(64)}\n    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:${'4'.repeat(64)}\n`,
  );

  const stub = buildStubRunner((call) =>
    call.argv[0] === 'gh'
      ? { exitCode: 1, stderr: 'HTTP 401: Bad credentials (https://api.github.com/graphql)\n' }
      : undefined,
  );

  const bumps = await readReleaseBumps(ctx.root, stub.run);

  expect(bumps).toStrictEqual(
    new Error('HTTP 401: Bad credentials (https://api.github.com/graphql)'),
  );
});

import { expect, mock, onTestFinished, test } from 'bun:test';
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildStubNixieAPIContract } from '../test-utils/build-stub-nixie-api-contract.ts';
import { buildStubReleaseDocker } from '../test-utils/build-stub-release-docker.ts';
import { buildStubRunner } from '../test-utils/build-stub-runner.ts';
import { getReleaseRecord } from '../test-utils/get-release-record.ts';
import { applyReleasePins } from './apply-release-pins.ts';

async function setupTest() {
  const root = await mkdtemp(join(tmpdir(), 'apply-release-pins-'));

  onTestFinished(() => rm(root, { recursive: true, force: true }));

  await Promise.all(
    [
      'nixos/hosts/geoffcloud',
      'nixos/packages',
      'images/agent',
      'images/atc-gateway',
      'infra',
      'scripts/nixie-api',
      'scripts/release',
    ].map((directory) => mkdir(join(root, directory), { recursive: true })),
  );

  const nixImageFile = await readFile(join(import.meta.dir, '../nix-image.sh'), 'utf8');

  return {
    root,
    nixImage: /^NIX_IMAGE='(?<image>[^']+)'$/mu.exec(nixImageFile)?.groups?.['image'] ?? '',
    checkout: join(import.meta.dir, '../..'),
    owner: `${process.getuid?.() ?? 0}:${process.getgid?.() ?? 0}`,
    printOut: mock<(text: string) => void>(),
  };
}

test('it pins the input, the lock and both images', async () => {
  const ctx = await setupTest();

  const files = {
    'nixos/flake.nix':
      '    imp = {\n      url = "github:zgeoff/impz/4211437b";\n      inputs.nixpkgs.follows = "nixpkgs";\n    };\n',
    'nixos/flake.lock': `{"nodes":{"imp":{"locked":{"rev":"${'4'.repeat(40)}"}}}}\n`,
    'nixos/hosts/geoffcloud/configuration.nix': `  services.imp = {\n    image = "ghcr.io/zgeoff/imp-host:1.0.0@sha256:${'1'.repeat(64)}";\n  };\n  services.preview = {\n    impRegistryImage = "ghcr.io/zgeoff/imp-base:0.33.0@sha256:${'2'.repeat(64)}";\n  };\n`,
    'images/agent/Dockerfile': `FROM ghcr.io/zgeoff/imp-base:0.33.0@sha256:${'2'.repeat(64)}\nARG ATC_VERSION=4.2.0\n`,
  };

  await Promise.all(
    Object.entries(files).map((entry: readonly [string, string]) =>
      writeFile(join(ctx.root, entry[0]), entry[1]),
    ),
  );

  await writeFile(join(ctx.root, 'scripts/release/release-pins.json'), '{}\n');

  const lock = `{"nodes":{"imp":{"locked":{"rev":"c5bea940${'c'.repeat(32)}"}}}}\n`;
  const stub = buildStubRunner(buildStubReleaseDocker({ lock }).handle);

  const applied = await applyReleasePins({
    record: getReleaseRecord('imp'),
    version: '1.0.1',
    values: {
      commit: `c5bea940${'c'.repeat(32)}`,
      digests: { 'imp-host': `sha256:${'3'.repeat(64)}`, 'imp-base': `sha256:${'4'.repeat(64)}` },
    },
    root: ctx.root,
    run: stub.run,
    env: {},
    printOut: ctx.printOut,
  });

  const tree = await Promise.all(
    Object.keys(files).map((path) => readFile(join(ctx.root, path), 'utf8')),
  );

  expect(applied).toBeUndefined();

  expect(tree).toStrictEqual([
    '    imp = {\n      url = "github:zgeoff/impz/c5bea940";\n      inputs.nixpkgs.follows = "nixpkgs";\n    };\n',
    lock,
    `  services.imp = {\n    image = "ghcr.io/zgeoff/imp-host:1.0.1@sha256:${'3'.repeat(64)}";\n  };\n  services.preview = {\n    impRegistryImage = "ghcr.io/zgeoff/imp-base:1.0.1@sha256:${'4'.repeat(64)}";\n  };\n`,
    `FROM ghcr.io/zgeoff/imp-base:1.0.1@sha256:${'4'.repeat(64)}\nARG ATC_VERSION=4.2.0\n`,
  ]);

  expect(ctx.printOut).toHaveBeenCalledExactlyOnceWith(
    'pinned imp-host 1.0.1\npinned imp-base 1.0.1\n',
  );
});

test('it locks the flake in the pinned Nix image and hands the lock back to the caller', async () => {
  const ctx = await setupTest();

  const files = {
    'nixos/flake.nix': '      url = "github:zgeoff/impz/4211437b";\n',
    'nixos/flake.lock': `{"nodes":{"imp":{"locked":{"rev":"${'4'.repeat(40)}"}}}}\n`,
    'nixos/hosts/geoffcloud/configuration.nix': `    image = "ghcr.io/zgeoff/imp-host:1.0.0@sha256:${'1'.repeat(64)}";\n    impRegistryImage = "ghcr.io/zgeoff/imp-base:1.0.0@sha256:${'2'.repeat(64)}";\n`,
    'images/agent/Dockerfile': `FROM ghcr.io/zgeoff/imp-base:1.0.0@sha256:${'2'.repeat(64)}\n`,
  };

  await Promise.all(
    Object.entries(files).map((entry: readonly [string, string]) =>
      writeFile(join(ctx.root, entry[0]), entry[1]),
    ),
  );

  await writeFile(join(ctx.root, 'scripts/release/release-pins.json'), '{}\n');

  const lock = `{"nodes":{"imp":{"locked":{"rev":"c5bea940${'c'.repeat(32)}"}}}}\n`;
  const stub = buildStubRunner(buildStubReleaseDocker({ lock }).handle);

  await applyReleasePins({
    record: getReleaseRecord('imp'),
    version: '1.0.1',
    values: {
      commit: `c5bea940${'c'.repeat(32)}`,
      digests: { 'imp-host': `sha256:${'3'.repeat(64)}`, 'imp-base': `sha256:${'4'.repeat(64)}` },
    },
    root: ctx.root,
    run: stub.run,
    env: {},
    printOut: ctx.printOut,
  });

  expect(stub.calls.map((call) => call.argv)).toStrictEqual([
    [
      'docker',
      'run',
      '--rm',
      '-v',
      `${ctx.root}/nixos:/src`,
      '-w',
      '/src',
      ctx.nixImage,
      'sh',
      '-c',
      `nix --extra-experimental-features 'nix-command flakes' flake lock && chown ${ctx.owner} flake.lock`,
    ],
  ]);
});

test('it hands the github token to the lock by its environment, never in an argv', async () => {
  const ctx = await setupTest();

  const files = {
    'nixos/flake.nix': '      url = "github:zgeoff/impz/4211437b";\n',
    'nixos/flake.lock': `{"nodes":{"imp":{"locked":{"rev":"${'4'.repeat(40)}"}}}}\n`,
    'nixos/hosts/geoffcloud/configuration.nix': `    image = "ghcr.io/zgeoff/imp-host:1.0.0@sha256:${'1'.repeat(64)}";\n    impRegistryImage = "ghcr.io/zgeoff/imp-base:1.0.0@sha256:${'2'.repeat(64)}";\n`,
    'images/agent/Dockerfile': `FROM ghcr.io/zgeoff/imp-base:1.0.0@sha256:${'2'.repeat(64)}\n`,
  };

  await Promise.all(
    Object.entries(files).map((entry: readonly [string, string]) =>
      writeFile(join(ctx.root, entry[0]), entry[1]),
    ),
  );

  await writeFile(join(ctx.root, 'scripts/release/release-pins.json'), '{}\n');

  const docker = buildStubReleaseDocker({
    lock: `{"nodes":{"imp":{"locked":{"rev":"c5bea940${'c'.repeat(32)}"}}}}\n`,
  });

  const stub = buildStubRunner(docker.handle);

  await applyReleasePins({
    record: getReleaseRecord('imp'),
    version: '1.0.1',
    values: {
      commit: `c5bea940${'c'.repeat(32)}`,
      digests: { 'imp-host': `sha256:${'3'.repeat(64)}`, 'imp-base': `sha256:${'4'.repeat(64)}` },
    },
    root: ctx.root,
    run: stub.run,
    env: { NIX_GITHUB_TOKEN: 'ghs_exampletoken' },
    printOut: ctx.printOut,
  });

  expect(docker.nixConfigs).toStrictEqual(['access-tokens = github.com=ghs_exampletoken']);

  expect(stub.calls.map((call) => call.argv.slice(5, 10))).toStrictEqual([
    ['-w', '/src', '-e', 'NIX_CONFIG', ctx.nixImage],
  ]);

  expect(JSON.stringify(stub.calls.map((call) => call.argv))).not.toInclude('ghs_exampletoken');
});

test('it adds the github token after the caller nix config', async () => {
  const ctx = await setupTest();

  const files = {
    'nixos/flake.nix': '      url = "github:zgeoff/impz/4211437b";\n',
    'nixos/flake.lock': `{"nodes":{"imp":{"locked":{"rev":"${'4'.repeat(40)}"}}}}\n`,
    'nixos/hosts/geoffcloud/configuration.nix': `    image = "ghcr.io/zgeoff/imp-host:1.0.0@sha256:${'1'.repeat(64)}";\n    impRegistryImage = "ghcr.io/zgeoff/imp-base:1.0.0@sha256:${'2'.repeat(64)}";\n`,
    'images/agent/Dockerfile': `FROM ghcr.io/zgeoff/imp-base:1.0.0@sha256:${'2'.repeat(64)}\n`,
  };

  await Promise.all(
    Object.entries(files).map((entry: readonly [string, string]) =>
      writeFile(join(ctx.root, entry[0]), entry[1]),
    ),
  );

  await writeFile(join(ctx.root, 'scripts/release/release-pins.json'), '{}\n');

  const docker = buildStubReleaseDocker({
    lock: `{"nodes":{"imp":{"locked":{"rev":"c5bea940${'c'.repeat(32)}"}}}}\n`,
  });

  const stub = buildStubRunner(docker.handle);

  await applyReleasePins({
    record: getReleaseRecord('imp'),
    version: '1.0.1',
    values: {
      commit: `c5bea940${'c'.repeat(32)}`,
      digests: { 'imp-host': `sha256:${'3'.repeat(64)}`, 'imp-base': `sha256:${'4'.repeat(64)}` },
    },
    root: ctx.root,
    run: stub.run,
    env: { NIX_CONFIG: 'connect-timeout = 5', NIX_GITHUB_TOKEN: 'ghs_exampletoken' },
    printOut: ctx.printOut,
  });

  expect(docker.nixConfigs).toStrictEqual([
    'connect-timeout = 5\naccess-tokens = github.com=ghs_exampletoken',
  ]);
});

test('it hands the lock no nix config without a github token', async () => {
  const ctx = await setupTest();

  const files = {
    'nixos/flake.nix': '      url = "github:zgeoff/impz/4211437b";\n',
    'nixos/flake.lock': `{"nodes":{"imp":{"locked":{"rev":"${'4'.repeat(40)}"}}}}\n`,
    'nixos/hosts/geoffcloud/configuration.nix': `    image = "ghcr.io/zgeoff/imp-host:1.0.0@sha256:${'1'.repeat(64)}";\n    impRegistryImage = "ghcr.io/zgeoff/imp-base:1.0.0@sha256:${'2'.repeat(64)}";\n`,
    'images/agent/Dockerfile': `FROM ghcr.io/zgeoff/imp-base:1.0.0@sha256:${'2'.repeat(64)}\n`,
  };

  await Promise.all(
    Object.entries(files).map((entry: readonly [string, string]) =>
      writeFile(join(ctx.root, entry[0]), entry[1]),
    ),
  );

  await writeFile(join(ctx.root, 'scripts/release/release-pins.json'), '{}\n');

  const docker = buildStubReleaseDocker({
    lock: `{"nodes":{"imp":{"locked":{"rev":"c5bea940${'c'.repeat(32)}"}}}}\n`,
  });

  const stub = buildStubRunner(docker.handle);

  await applyReleasePins({
    record: getReleaseRecord('imp'),
    version: '1.0.1',
    values: {
      commit: `c5bea940${'c'.repeat(32)}`,
      digests: { 'imp-host': `sha256:${'3'.repeat(64)}`, 'imp-base': `sha256:${'4'.repeat(64)}` },
    },
    root: ctx.root,
    run: stub.run,
    env: { NIX_CONFIG: 'access-tokens = example.invalid=other' },
    printOut: ctx.printOut,
  });

  expect(docker.nixConfigs).toStrictEqual([undefined]);
});

test('it keeps a newer imp-base and pins the host', async () => {
  const ctx = await setupTest();

  const files = {
    'nixos/flake.nix': '      url = "github:zgeoff/impz/4211437b";\n',
    'nixos/flake.lock': `{"nodes":{"imp":{"locked":{"rev":"${'4'.repeat(40)}"}}}}\n`,
    'nixos/hosts/geoffcloud/configuration.nix': `    image = "ghcr.io/zgeoff/imp-host:1.0.0@sha256:${'1'.repeat(64)}";\n    impRegistryImage = "ghcr.io/zgeoff/imp-base:1.0.2@sha256:${'5'.repeat(64)}";\n`,
    'images/agent/Dockerfile': `FROM ghcr.io/zgeoff/imp-base:1.0.2@sha256:${'5'.repeat(64)}\n`,
  };

  await Promise.all(
    Object.entries(files).map((entry: readonly [string, string]) =>
      writeFile(join(ctx.root, entry[0]), entry[1]),
    ),
  );

  await writeFile(join(ctx.root, 'scripts/release/release-pins.json'), '{}\n');

  const lock = `{"nodes":{"imp":{"locked":{"rev":"c5bea940${'c'.repeat(32)}"}}}}\n`;
  const stub = buildStubRunner(buildStubReleaseDocker({ lock }).handle);

  await applyReleasePins({
    record: getReleaseRecord('imp'),
    version: '1.0.1',
    values: {
      commit: `c5bea940${'c'.repeat(32)}`,
      digests: { 'imp-host': `sha256:${'3'.repeat(64)}`, 'imp-base': `sha256:${'4'.repeat(64)}` },
    },
    root: ctx.root,
    run: stub.run,
    env: {},
    printOut: ctx.printOut,
  });

  const tree = await Promise.all(
    Object.keys(files).map((path) => readFile(join(ctx.root, path), 'utf8')),
  );

  expect(tree).toStrictEqual([
    '      url = "github:zgeoff/impz/c5bea940";\n',
    lock,
    `    image = "ghcr.io/zgeoff/imp-host:1.0.1@sha256:${'3'.repeat(64)}";\n    impRegistryImage = "ghcr.io/zgeoff/imp-base:1.0.2@sha256:${'5'.repeat(64)}";\n`,
    `FROM ghcr.io/zgeoff/imp-base:1.0.2@sha256:${'5'.repeat(64)}\n`,
  ]);

  expect(ctx.printOut).toHaveBeenCalledExactlyOnceWith(
    'pinned imp-host 1.0.1\nimp-base pins 1.0.2, which is newer than 1.0.1\n',
  );
});

test('it runs no lock when imp-host already holds the release', async () => {
  const ctx = await setupTest();

  const files = {
    'nixos/flake.nix': '      url = "github:zgeoff/impz/c5bea940";\n',
    'nixos/flake.lock': `{"nodes":{"imp":{"locked":{"rev":"c5bea940${'c'.repeat(32)}"}}}}\n`,
    'nixos/hosts/geoffcloud/configuration.nix': `    image = "ghcr.io/zgeoff/imp-host:1.0.1@sha256:${'3'.repeat(64)}";\n    impRegistryImage = "ghcr.io/zgeoff/imp-base:0.33.0@sha256:${'2'.repeat(64)}";\n`,
    'images/agent/Dockerfile': `FROM ghcr.io/zgeoff/imp-base:0.33.0@sha256:${'2'.repeat(64)}\n`,
  };

  await Promise.all(
    Object.entries(files).map((entry: readonly [string, string]) =>
      writeFile(join(ctx.root, entry[0]), entry[1]),
    ),
  );

  await writeFile(join(ctx.root, 'scripts/release/release-pins.json'), '{}\n');

  const stub = buildStubRunner(buildStubReleaseDocker({}).handle);

  await applyReleasePins({
    record: getReleaseRecord('imp'),
    version: '1.0.1',
    values: {
      commit: `c5bea940${'c'.repeat(32)}`,
      digests: { 'imp-host': `sha256:${'3'.repeat(64)}`, 'imp-base': `sha256:${'4'.repeat(64)}` },
    },
    root: ctx.root,
    run: stub.run,
    env: {},
    printOut: ctx.printOut,
  });

  const tree = await Promise.all(
    Object.keys(files).map((path) => readFile(join(ctx.root, path), 'utf8')),
  );

  expect(tree).toStrictEqual([
    '      url = "github:zgeoff/impz/c5bea940";\n',
    `{"nodes":{"imp":{"locked":{"rev":"c5bea940${'c'.repeat(32)}"}}}}\n`,
    `    image = "ghcr.io/zgeoff/imp-host:1.0.1@sha256:${'3'.repeat(64)}";\n    impRegistryImage = "ghcr.io/zgeoff/imp-base:1.0.1@sha256:${'4'.repeat(64)}";\n`,
    `FROM ghcr.io/zgeoff/imp-base:1.0.1@sha256:${'4'.repeat(64)}\n`,
  ]);

  expect(stub.calls).toStrictEqual([]);

  expect(ctx.printOut).toHaveBeenCalledExactlyOnceWith(
    'imp-host already pins 1.0.1\npinned imp-base 1.0.1\n',
  );
});

test('it refuses a lock that names another commit', async () => {
  const ctx = await setupTest();

  const files = {
    'nixos/flake.nix': '      url = "github:zgeoff/impz/4211437b";\n',
    'nixos/flake.lock': `{"nodes":{"imp":{"locked":{"rev":"${'4'.repeat(40)}"}}}}\n`,
    'nixos/hosts/geoffcloud/configuration.nix': `    image = "ghcr.io/zgeoff/imp-host:1.0.0@sha256:${'1'.repeat(64)}";\n    impRegistryImage = "ghcr.io/zgeoff/imp-base:1.0.0@sha256:${'2'.repeat(64)}";\n`,
    'images/agent/Dockerfile': `FROM ghcr.io/zgeoff/imp-base:1.0.0@sha256:${'2'.repeat(64)}\n`,
  };

  await Promise.all(
    Object.entries(files).map((entry: readonly [string, string]) =>
      writeFile(join(ctx.root, entry[0]), entry[1]),
    ),
  );

  await writeFile(join(ctx.root, 'scripts/release/release-pins.json'), '{}\n');

  const lock = `{"nodes":{"imp":{"locked":{"rev":"${'9'.repeat(40)}"}}}}\n`;
  const stub = buildStubRunner(buildStubReleaseDocker({ lock }).handle);

  const applied = await applyReleasePins({
    record: getReleaseRecord('imp'),
    version: '1.0.1',
    values: {
      commit: `c5bea940${'c'.repeat(32)}`,
      digests: { 'imp-host': `sha256:${'3'.repeat(64)}`, 'imp-base': `sha256:${'4'.repeat(64)}` },
    },
    root: ctx.root,
    run: stub.run,
    env: {},
    printOut: ctx.printOut,
  });

  expect(applied).toStrictEqual(
    new Error(`nixos/flake.lock locks imp at ${'9'.repeat(40)}, want c5bea940${'c'.repeat(32)}`),
  );

  expect(ctx.printOut).not.toHaveBeenCalled();
});

test('it fails with the lock error when the lock fails', async () => {
  const ctx = await setupTest();

  const files = {
    'nixos/flake.nix': '      url = "github:zgeoff/impz/4211437b";\n',
    'nixos/flake.lock': `{"nodes":{"imp":{"locked":{"rev":"${'4'.repeat(40)}"}}}}\n`,
    'nixos/hosts/geoffcloud/configuration.nix': `    image = "ghcr.io/zgeoff/imp-host:1.0.0@sha256:${'1'.repeat(64)}";\n    impRegistryImage = "ghcr.io/zgeoff/imp-base:1.0.0@sha256:${'2'.repeat(64)}";\n`,
    'images/agent/Dockerfile': `FROM ghcr.io/zgeoff/imp-base:1.0.0@sha256:${'2'.repeat(64)}\n`,
  };

  await Promise.all(
    Object.entries(files).map((entry: readonly [string, string]) =>
      writeFile(join(ctx.root, entry[0]), entry[1]),
    ),
  );

  await writeFile(join(ctx.root, 'scripts/release/release-pins.json'), '{}\n');

  const lockError =
    "error: unable to download 'https://api.github.com/repos/zgeoff/impz/commits/c5bea940'";

  const stub = buildStubRunner(buildStubReleaseDocker({ lockError }).handle);

  const applied = await applyReleasePins({
    record: getReleaseRecord('imp'),
    version: '1.0.1',
    values: {
      commit: `c5bea940${'c'.repeat(32)}`,
      digests: { 'imp-host': `sha256:${'3'.repeat(64)}`, 'imp-base': `sha256:${'4'.repeat(64)}` },
    },
    root: ctx.root,
    run: stub.run,
    env: {},
    printOut: ctx.printOut,
  });

  const lock = await readFile(join(ctx.root, 'nixos/flake.lock'), 'utf8');

  expect(applied).toStrictEqual(new Error(lockError));
  expect(lock).toBe(`{"nodes":{"imp":{"locked":{"rev":"${'4'.repeat(40)}"}}}}\n`);
  expect(ctx.printOut).not.toHaveBeenCalled();
});

test("it writes the record's pin table entries with its pins", async () => {
  const ctx = await setupTest();

  const files = {
    'nixos/flake.nix': '      url = "github:zgeoff/impz/4211437b";\n',
    'nixos/flake.lock': `{"nodes":{"imp":{"locked":{"rev":"${'4'.repeat(40)}"}}}}\n`,
    'nixos/hosts/geoffcloud/configuration.nix': `    image = "ghcr.io/zgeoff/imp-host:1.0.0@sha256:${'1'.repeat(64)}";\n    impRegistryImage = "ghcr.io/zgeoff/imp-base:1.0.0@sha256:${'2'.repeat(64)}";\n`,
    'images/agent/Dockerfile': `FROM ghcr.io/zgeoff/imp-base:1.0.0@sha256:${'2'.repeat(64)}\n`,
  };

  await Promise.all(
    Object.entries(files).map((entry: readonly [string, string]) =>
      writeFile(join(ctx.root, entry[0]), entry[1]),
    ),
  );

  await writeFile(
    join(ctx.root, 'scripts/release/release-pins.json'),
    `{\n  "imp-base": {\n    "version": "1.0.0",\n    "digest": "sha256:${'2'.repeat(64)}"\n  },\n  "nixie": {\n    "version": "0.7.0",\n    "digest": "sha256:${'5'.repeat(64)}"\n  }\n}\n`,
  );

  const lock = `{"nodes":{"imp":{"locked":{"rev":"c5bea940${'c'.repeat(32)}"}}}}\n`;
  const stub = buildStubRunner(buildStubReleaseDocker({ lock }).handle);

  await applyReleasePins({
    record: getReleaseRecord('imp'),
    version: '1.0.1',
    values: {
      commit: `c5bea940${'c'.repeat(32)}`,
      digests: { 'imp-host': `sha256:${'3'.repeat(64)}`, 'imp-base': `sha256:${'4'.repeat(64)}` },
    },
    root: ctx.root,
    run: stub.run,
    env: {},
    printOut: ctx.printOut,
  });

  const table = await readFile(join(ctx.root, 'scripts/release/release-pins.json'), 'utf8');

  expect(table).toBe(
    `{\n  "imp-host": {\n    "version": "1.0.1",\n    "digest": "sha256:${'3'.repeat(64)}",\n    "commit": "c5bea940"\n  },\n  "imp-base": {\n    "version": "1.0.1",\n    "digest": "sha256:${'4'.repeat(64)}"\n  },\n  "nixie": {\n    "version": "0.7.0",\n    "digest": "sha256:${'5'.repeat(64)}"\n  }\n}\n`,
  );
});

test('it puts the pin table back when the lock fails', async () => {
  const ctx = await setupTest();

  const files = {
    'nixos/flake.nix': '      url = "github:zgeoff/impz/4211437b";\n',
    'nixos/flake.lock': `{"nodes":{"imp":{"locked":{"rev":"${'4'.repeat(40)}"}}}}\n`,
    'nixos/hosts/geoffcloud/configuration.nix': `    image = "ghcr.io/zgeoff/imp-host:1.0.0@sha256:${'1'.repeat(64)}";\n    impRegistryImage = "ghcr.io/zgeoff/imp-base:1.0.0@sha256:${'2'.repeat(64)}";\n`,
    'images/agent/Dockerfile': `FROM ghcr.io/zgeoff/imp-base:1.0.0@sha256:${'2'.repeat(64)}\n`,
    'scripts/release/release-pins.json': `{\n  "imp-base": {\n    "version": "1.0.0",\n    "digest": "sha256:${'2'.repeat(64)}"\n  }\n}\n`,
  };

  await Promise.all(
    Object.entries(files).map((entry: readonly [string, string]) =>
      writeFile(join(ctx.root, entry[0]), entry[1]),
    ),
  );

  const lockError =
    "error: unable to download 'https://api.github.com/repos/zgeoff/impz/commits/c5bea940'";

  const stub = buildStubRunner(buildStubReleaseDocker({ lockError }).handle);

  const applied = await applyReleasePins({
    record: getReleaseRecord('imp'),
    version: '1.0.1',
    values: {
      commit: `c5bea940${'c'.repeat(32)}`,
      digests: { 'imp-host': `sha256:${'3'.repeat(64)}`, 'imp-base': `sha256:${'4'.repeat(64)}` },
    },
    root: ctx.root,
    run: stub.run,
    env: {},
    printOut: ctx.printOut,
  });

  const tree = await Promise.all(
    Object.keys(files).map((path) => readFile(join(ctx.root, path), 'utf8')),
  );

  expect(applied).toStrictEqual(new Error(lockError));
  expect(tree).toStrictEqual(Object.values(files));
});

test('it refuses the release pinned with another digest without writing', async () => {
  const ctx = await setupTest();

  const files = {
    'nixos/flake.nix': '      url = "github:zgeoff/impz/c5bea940";\n',
    'nixos/flake.lock': `{"nodes":{"imp":{"locked":{"rev":"c5bea940${'c'.repeat(32)}"}}}}\n`,
    'nixos/hosts/geoffcloud/configuration.nix': `    image = "ghcr.io/zgeoff/imp-host:1.0.1@sha256:${'1'.repeat(64)}";\n    impRegistryImage = "ghcr.io/zgeoff/imp-base:1.0.0@sha256:${'2'.repeat(64)}";\n`,
    'images/agent/Dockerfile': `FROM ghcr.io/zgeoff/imp-base:1.0.0@sha256:${'2'.repeat(64)}\n`,
  };

  await Promise.all(
    Object.entries(files).map((entry: readonly [string, string]) =>
      writeFile(join(ctx.root, entry[0]), entry[1]),
    ),
  );

  await writeFile(join(ctx.root, 'scripts/release/release-pins.json'), '{}\n');

  const stub = buildStubRunner(buildStubReleaseDocker({}).handle);

  const applied = await applyReleasePins({
    record: getReleaseRecord('imp'),
    version: '1.0.1',
    values: {
      commit: `c5bea940${'c'.repeat(32)}`,
      digests: { 'imp-host': `sha256:${'3'.repeat(64)}`, 'imp-base': `sha256:${'4'.repeat(64)}` },
    },
    root: ctx.root,
    run: stub.run,
    env: {},
    printOut: ctx.printOut,
  });

  const tree = await Promise.all(
    Object.keys(files).map((path) => readFile(join(ctx.root, path), 'utf8')),
  );

  expect(applied).toStrictEqual(
    new Error(
      `imp-host pins 1.0.1 with sha256:${'1'.repeat(64)}, but the release lists sha256:${'3'.repeat(64)}`,
    ),
  );

  expect(tree).toStrictEqual(Object.values(files));
  expect(stub.calls).toStrictEqual([]);
});

test('it refuses imp-base pins that disagree without writing', async () => {
  const ctx = await setupTest();

  const files = {
    'nixos/flake.nix': '      url = "github:zgeoff/impz/4211437b";\n',
    'nixos/flake.lock': `{"nodes":{"imp":{"locked":{"rev":"${'4'.repeat(40)}"}}}}\n`,
    'nixos/hosts/geoffcloud/configuration.nix': `    image = "ghcr.io/zgeoff/imp-host:1.0.0@sha256:${'1'.repeat(64)}";\n    impRegistryImage = "ghcr.io/zgeoff/imp-base:0.33.0@sha256:${'2'.repeat(64)}";\n`,
    'images/agent/Dockerfile': `FROM ghcr.io/zgeoff/imp-base:1.0.0@sha256:${'2'.repeat(64)}\n`,
  };

  await Promise.all(
    Object.entries(files).map((entry: readonly [string, string]) =>
      writeFile(join(ctx.root, entry[0]), entry[1]),
    ),
  );

  await writeFile(join(ctx.root, 'scripts/release/release-pins.json'), '{}\n');

  const stub = buildStubRunner(buildStubReleaseDocker({}).handle);

  const applied = await applyReleasePins({
    record: getReleaseRecord('imp'),
    version: '1.0.1',
    values: {
      commit: `c5bea940${'c'.repeat(32)}`,
      digests: { 'imp-host': `sha256:${'3'.repeat(64)}`, 'imp-base': `sha256:${'4'.repeat(64)}` },
    },
    root: ctx.root,
    run: stub.run,
    env: {},
    printOut: ctx.printOut,
  });

  const tree = await Promise.all(
    Object.keys(files).map((path) => readFile(join(ctx.root, path), 'utf8')),
  );

  expect(applied).toStrictEqual(
    new Error('imp-base pins 1.0.0 in one line and 0.33.0 in another: pin both at one release'),
  );

  expect(tree).toStrictEqual(Object.values(files));
  expect(stub.calls).toStrictEqual([]);
});

test('it pins an atc release in the real pin files and keeps every other line', async () => {
  const ctx = await setupTest();

  const paths = [
    'images/agent/Dockerfile',
    'nixos/packages/atc.nix',
    'images/atc-gateway/versions.env',
  ];

  await Promise.all(paths.map((path) => copyFile(join(ctx.checkout, path), join(ctx.root, path))));

  await copyFile(
    join(ctx.checkout, 'scripts/release/release-pins.json'),
    join(ctx.root, 'scripts/release/release-pins.json'),
  );

  const before = await Promise.all(paths.map((path) => readFile(join(ctx.root, path), 'utf8')));

  const stub = buildStubRunner();

  await applyReleasePins({
    record: getReleaseRecord('atc'),
    version: '99.0.0',
    values: {
      sha256sums: `${'a'.repeat(64)}  atc-linux-x64\n${'b'.repeat(64)}  atc-gateway-linux-x64\n`,
    },
    root: ctx.root,
    run: stub.run,
    env: {},
    printOut: ctx.printOut,
  });

  const tree = await Promise.all(paths.map((path) => readFile(join(ctx.root, path), 'utf8')));

  expect(tree).toStrictEqual([
    (before[0] ?? '')
      .replace(/^ARG ATC_VERSION=.*$/mu, 'ARG ATC_VERSION=99.0.0')
      .replace(/^ARG ATC_SHA256=.*$/mu, `ARG ATC_SHA256=${'a'.repeat(64)}`),
    (before[1] ?? '')
      .replace(/^ {2}version = ".*";$/mu, '  version = "99.0.0";')
      .replace(/^ {2}sha256 = ".*";$/mu, `  sha256 = "${'a'.repeat(64)}";`),
    (before[2] ?? '')
      .replace(/^ATC_RELEASE=.*$/mu, 'ATC_RELEASE=@zgeoff/atc@99.0.0')
      .replace(/^ATC_ASSET_SHA256=.*$/mu, `ATC_ASSET_SHA256=${'b'.repeat(64)}`)
      .replace(/^GATEWAY_IMAGE_TAG=.*$/mu, 'GATEWAY_IMAGE_TAG=99.0.0'),
  ]);

  expect(stub.calls).toStrictEqual([]);

  expect(ctx.printOut).toHaveBeenCalledExactlyOnceWith(
    'pinned atc-agent 99.0.0\npinned atc-daemon 99.0.0\npinned atc-gateway 99.0.0\n',
  );
});

test('it regenerates the nixie contract for the release tag after the pins', async () => {
  const ctx = await setupTest();

  const files = {
    'infra/Pulumi.prod.yaml': `nixie:\n    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:${'a'.repeat(64)}\n    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:${'b'.repeat(64)}\n`,
    'scripts/nixie-api/openapi.json': '{"info":{"version":"v0.7.0"}}\n',
    'scripts/nixie-api/openapi.d.ts': '// nixie v0.7.0\n',
    'scripts/release/release-pins.json': '{}\n',
  };

  await Promise.all(
    Object.entries(files).map((entry: readonly [string, string]) =>
      writeFile(join(ctx.root, entry[0]), entry[1]),
    ),
  );

  const stub = buildStubRunner(buildStubNixieAPIContract({}));

  const applied = await applyReleasePins({
    record: getReleaseRecord('nixie'),
    version: '0.7.2',
    values: {
      digests: { nixie: `sha256:${'d'.repeat(64)}`, 'nixie-web': `sha256:${'e'.repeat(64)}` },
    },
    root: ctx.root,
    run: stub.run,
    env: { GH_TOKEN: 'ghs_exampletoken' },
    printOut: ctx.printOut,
  });

  const tree = await Promise.all(
    [
      'infra/Pulumi.prod.yaml',
      'scripts/nixie-api/openapi.json',
      'scripts/nixie-api/openapi.d.ts',
    ].map((path) => readFile(join(ctx.root, path), 'utf8')),
  );

  expect(applied).toBeUndefined();

  expect(tree).toStrictEqual([
    `nixie:\n    image: ghcr.io/zgeoff/nixie:0.7.2@sha256:${'d'.repeat(64)}\n    webImage: ghcr.io/zgeoff/nixie-web:0.7.2@sha256:${'e'.repeat(64)}\n`,
    '{"info":{"version":"v0.7.2"}}\n',
    '// nixie v0.7.2\n',
  ]);

  expect(stub.calls).toStrictEqual([
    {
      argv: ['bun', join(ctx.root, 'scripts/nixie-api/write-nixie-api-contract.ts'), 'v0.7.2'],
      stdin: '',
      options: { cwd: ctx.root, env: { GH_TOKEN: 'ghs_exampletoken' } },
    },
  ]);
});

test('it puts the pins and the pin table back when the contract fails to generate', async () => {
  const ctx = await setupTest();

  const files = {
    'infra/Pulumi.prod.yaml': `nixie:\n    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:${'a'.repeat(64)}\n    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:${'b'.repeat(64)}\n`,
    'scripts/nixie-api/openapi.json': '{"info":{"version":"v0.7.0"}}\n',
    'scripts/nixie-api/openapi.d.ts': '// nixie v0.7.0\n',
    'scripts/release/release-pins.json': '{}\n',
  };

  await Promise.all(
    Object.entries(files).map((entry: readonly [string, string]) =>
      writeFile(join(ctx.root, entry[0]), entry[1]),
    ),
  );

  const stub = buildStubRunner(buildStubNixieAPIContract({ error: 'gh: Not Found (HTTP 404)' }));

  const applied = await applyReleasePins({
    record: getReleaseRecord('nixie'),
    version: '0.7.2',
    values: {
      digests: { nixie: `sha256:${'d'.repeat(64)}`, 'nixie-web': `sha256:${'e'.repeat(64)}` },
    },
    root: ctx.root,
    run: stub.run,
    env: {},
    printOut: ctx.printOut,
  });

  const tree = await Promise.all(
    Object.keys(files).map((path) => readFile(join(ctx.root, path), 'utf8')),
  );

  expect(applied).toStrictEqual(new Error('gh: Not Found (HTTP 404)'));
  expect(tree).toStrictEqual(Object.values(files));
  expect(ctx.printOut).not.toHaveBeenCalled();
});

test('it refuses a checkout that lacks a pin file', async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner();

  const applied = await applyReleasePins({
    record: getReleaseRecord('auto-mode'),
    version: '2.1.0',
    values: { tarballSum: 'd'.repeat(64) },
    root: join(ctx.root, 'missing'),
    run: stub.run,
    env: {},
    printOut: ctx.printOut,
  });

  expect(applied).toStrictEqual(
    new Error(
      'images/agent/Dockerfile is missing: run this from the root of a zgeoff/cloud checkout',
    ),
  );
});

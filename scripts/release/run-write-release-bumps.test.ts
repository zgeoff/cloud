import { expect, mock, onTestFinished, test } from 'bun:test';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildStubReleaseGH } from '../test-utils/build-stub-release-gh.ts';
import { buildStubRunner } from '../test-utils/build-stub-runner.ts';
import { createCloudCheckout } from '../test-utils/create-cloud-checkout.ts';
import { runWriteReleaseBumps } from './run-write-release-bumps.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'run-write-release-bumps-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const output = join(directory, 'output');
  const summary = join(directory, 'summary');

  // boot data: the runner creates both files before a step runs
  await Promise.all([writeFile(output, ''), writeFile(summary, '')]);

  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  return { output, summary, printOut, printErr };
}

test('it writes each bump as the bumps output and lists them', async () => {
  const ctx = await setupTest();

  const checkout = await createCloudCheckout({
    'images/agent/Dockerfile': `FROM ghcr.io/zgeoff/imp-base:1.0.0@sha256:${'2'.repeat(64)}\nARG ATC_VERSION=4.3.0\nARG AUTO_MODE_VERSION=0.19.3\n`,
    'nixos/packages/atc.nix': '  version = "4.2.0";\n',
    'images/atc-gateway/versions.env': 'ATC_RELEASE=@zgeoff/atc@4.3.0\n',
    'nixos/hosts/geoffcloud/configuration.nix': `    image = "ghcr.io/zgeoff/imp-host:1.0.0@sha256:${'1'.repeat(64)}";\n`,
    'infra/Pulumi.prod.yaml': `    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:${'3'.repeat(64)}\n    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:${'4'.repeat(64)}\n`,
    'package.json': '{\n  "devDependencies": {\n    "@heynixie/contract": "0.7.0"\n  }\n}\n',
  });

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

  const status = await runWriteReleaseBumps({
    env: { GITHUB_OUTPUT: ctx.output, GITHUB_STEP_SUMMARY: ctx.summary },
    root: checkout.clone,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const [output, summary] = await Promise.all([
    readFile(ctx.output, 'utf8'),
    readFile(ctx.summary, 'utf8'),
  ]);

  expect(status).toBe(0);

  expect(ctx.printOut.mock.calls).toStrictEqual([
    [
      'Pins older than their newest release (dependency, newest, pinned):\n\n- atc 4.3.0 4.3.0 4.2.0 4.3.0\n- imp 1.0.1 1.0.0 1.0.0\n',
    ],
  ]);

  expect(ctx.printErr.mock.calls).toStrictEqual([]);
  expect(output).toBe('bumps<<EOF\natc 4.3.0 4.3.0 4.2.0 4.3.0\nimp 1.0.1 1.0.0 1.0.0\nEOF\n');

  expect(summary).toBe(
    'Pins older than their newest release (dependency, newest, pinned):\n\n- atc 4.3.0 4.3.0 4.2.0 4.3.0\n- imp 1.0.1 1.0.0 1.0.0\n',
  );
});

test('it says every pin is current and writes no output', async () => {
  const ctx = await setupTest();

  const checkout = await createCloudCheckout({
    'images/agent/Dockerfile': `FROM ghcr.io/zgeoff/imp-base:1.0.1@sha256:${'2'.repeat(64)}\nARG ATC_VERSION=4.3.0\nARG AUTO_MODE_VERSION=0.19.3\n`,
    'nixos/packages/atc.nix': '  version = "4.3.0";\n',
    'images/atc-gateway/versions.env': 'ATC_RELEASE=@zgeoff/atc@4.3.0\n',
    'nixos/hosts/geoffcloud/configuration.nix': `    image = "ghcr.io/zgeoff/imp-host:1.0.1@sha256:${'1'.repeat(64)}";\n`,
    'infra/Pulumi.prod.yaml': `    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:${'3'.repeat(64)}\n    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:${'4'.repeat(64)}\n`,
    'package.json': '{\n  "devDependencies": {\n    "@heynixie/contract": "0.7.0"\n  }\n}\n',
  });

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

  const status = await runWriteReleaseBumps({
    env: { GITHUB_OUTPUT: ctx.output, GITHUB_STEP_SUMMARY: ctx.summary },
    root: checkout.clone,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const [output, summary] = await Promise.all([
    readFile(ctx.output, 'utf8'),
    readFile(ctx.summary, 'utf8'),
  ]);

  expect(status).toBe(0);
  expect(ctx.printOut.mock.calls).toStrictEqual([['Every pin holds its newest release.\n']]);
  expect(ctx.printErr.mock.calls).toStrictEqual([]);
  expect(output).toBe('');
  expect(summary).toBe('Every pin holds its newest release.\n');
});

test('it fails with the search error and writes nothing', async () => {
  const ctx = await setupTest();

  const checkout = await createCloudCheckout({
    'images/agent/Dockerfile': `FROM ghcr.io/zgeoff/imp-base:1.0.1@sha256:${'2'.repeat(64)}\nARG ATC_VERSION=4.3.0\nARG AUTO_MODE_VERSION=0.19.3\n`,
    'nixos/packages/atc.nix': '  version = "4.3.0";\n',
    'images/atc-gateway/versions.env': 'ATC_RELEASE=@zgeoff/atc@4.3.0\n',
    'nixos/hosts/geoffcloud/configuration.nix': `    image = "ghcr.io/zgeoff/imp-host:1.0.1@sha256:${'1'.repeat(64)}";\n`,
    'infra/Pulumi.prod.yaml': `    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:${'3'.repeat(64)}\n    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:${'4'.repeat(64)}\n`,
    'package.json': '{\n  "devDependencies": {\n    "@heynixie/contract": "0.7.0"\n  }\n}\n',
  });

  const stub = buildStubRunner(buildStubReleaseGH({ releases: {} }));

  const status = await runWriteReleaseBumps({
    env: { GITHUB_OUTPUT: ctx.output, GITHUB_STEP_SUMMARY: ctx.summary },
    root: checkout.clone,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const [output, summary] = await Promise.all([
    readFile(ctx.output, 'utf8'),
    readFile(ctx.summary, 'utf8'),
  ]);

  expect(status).toBe(1);
  expect(ctx.printOut.mock.calls).toStrictEqual([]);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['zgeoff/atc has no release tagged @zgeoff/atc@X.Y.Z\n'],
  ]);

  expect(output).toBe('');
  expect(summary).toBe('');
});

test('it fails without a step summary file', async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner();

  const status = await runWriteReleaseBumps({
    env: { GITHUB_OUTPUT: ctx.output },
    root: '/nonexistent/checkout',
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const output = await readFile(ctx.output, 'utf8');

  expect(status).toBe(2);
  expect(ctx.printOut.mock.calls).toStrictEqual([]);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ["GITHUB_STEP_SUMMARY must be set, as the workflow's runner sets it\n"],
  ]);

  expect(output).toBe('');
  expect(stub.calls).toStrictEqual([]);
});

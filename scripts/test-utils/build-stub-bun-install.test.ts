import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildStubBunInstall } from './build-stub-bun-install.ts';
import { buildStubRunner } from './build-stub-runner.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'build-stub-bun-install-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  return { directory };
}

test('it writes the scenario lock into the working directory', async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner(buildStubBunInstall({ lock: '{\n  "lockfileVersion": 1,\n}\n' }));

  const result = await stub.run(['bun', 'install', '--lockfile-only'], { cwd: ctx.directory });
  const lock = await readFile(join(ctx.directory, 'bun.lock'), 'utf8');

  expect(result.exitCode).toBe(0);
  expect(lock).toBe('{\n  "lockfileVersion": 1,\n}\n');
});

test('it fails with the scenario error as bun does for a version it cannot resolve', async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner(
    buildStubBunInstall({
      error: 'error: @heynixie/contract@0.9.0 failed to resolve',
    }),
  );

  const result = await stub.run(['bun', 'install', '--lockfile-only'], { cwd: ctx.directory });

  expect({ exitCode: result.exitCode, stderr: result.stderr.toString() }).toStrictEqual({
    exitCode: 1,
    stderr: 'error: @heynixie/contract@0.9.0 failed to resolve\n',
  });
});

test('it leaves an install that is not lock-only to the other handlers', async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner(buildStubBunInstall({ lock: '{}\n' }));

  const result = await stub.run(['bun', 'install'], { cwd: ctx.directory });

  expect({ exitCode: result.exitCode, stderr: result.stderr.toString() }).toStrictEqual({
    exitCode: 97,
    stderr: 'unexpected: ["bun","install"]\n',
  });
});

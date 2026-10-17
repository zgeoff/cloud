import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildStubReleaseDocker } from './build-stub-release-docker.ts';
import { buildStubRunner } from './build-stub-runner.ts';

async function setupTest() {
  const dir = await mkdtemp(join(tmpdir(), 'build-stub-release-docker-'));

  onTestFinished(() => rm(dir, { recursive: true, force: true }));

  return { dir };
}

test('it prints the manifest descriptor of a reference the scenario names', async () => {
  const docker = buildStubReleaseDocker({
    manifests: { 'ghcr.io/zgeoff/imp-host:1.0.1': `sha256:${'3'.repeat(64)}` },
  });

  const stub = buildStubRunner(docker.handle);

  const result = await stub.run([
    'docker',
    'buildx',
    'imagetools',
    'inspect',
    'ghcr.io/zgeoff/imp-host:1.0.1',
    '--format',
    '{{json .Manifest}}',
  ]);

  expect(JSON.parse(result.stdout.toString())).toStrictEqual({
    mediaType: 'application/vnd.oci.image.index.v1+json',
    digest: `sha256:${'3'.repeat(64)}`,
    size: 1609,
  });
});

test('it fails the inspect of an unknown reference as buildx does', async () => {
  const stub = buildStubRunner(buildStubReleaseDocker({}).handle);

  const result = await stub.run([
    'docker',
    'buildx',
    'imagetools',
    'inspect',
    'ghcr.io/zgeoff/imp-host:1.0.1',
    '--format',
    '{{json .Manifest}}',
  ]);

  expect({ exitCode: result.exitCode, stderr: result.stderr.toString() }).toStrictEqual({
    exitCode: 1,
    stderr: 'ERROR: ghcr.io/zgeoff/imp-host:1.0.1: not found\n',
  });
});

test('it writes the scenario lock into the mounted flake and hands it no NIX_CONFIG without -e', async () => {
  const ctx = await setupTest();

  const docker = buildStubReleaseDocker({ lock: '{"nodes":{}}\n' });
  const stub = buildStubRunner(docker.handle);

  const result = await stub.run(
    [
      'docker',
      'run',
      '--rm',
      '-v',
      `${ctx.dir}:/src`,
      '-w',
      '/src',
      'example/nix:1.0.0',
      'sh',
      '-c',
      "nix --extra-experimental-features 'nix-command flakes' flake lock && chown 1000:1000 flake.lock",
    ],
    { env: { NIX_CONFIG: 'connect-timeout = 5' } },
  );

  const lock = await readFile(join(ctx.dir, 'flake.lock'), 'utf8');

  expect(result.exitCode).toBe(0);
  expect(lock).toBe('{"nodes":{}}\n');
  expect(docker.nixConfigs).toStrictEqual([undefined]);
});

test('it hands the lock the caller NIX_CONFIG with -e NIX_CONFIG', async () => {
  const ctx = await setupTest();

  const docker = buildStubReleaseDocker({ lock: '{}\n' });
  const stub = buildStubRunner(docker.handle);

  await stub.run(
    [
      'docker',
      'run',
      '--rm',
      '-v',
      `${ctx.dir}:/src`,
      '-w',
      '/src',
      '-e',
      'NIX_CONFIG',
      'example/nix:1.0.0',
      'sh',
      '-c',
      'nix flake lock',
    ],
    { env: { NIX_CONFIG: 'access-tokens = github.com=example' } },
  );

  expect(docker.nixConfigs).toStrictEqual(['access-tokens = github.com=example']);
});

test('it fails a lock with the scenario error and leaves the lock unchanged', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.dir, 'flake.lock'), 'before\n');

  const stub = buildStubRunner(
    buildStubReleaseDocker({ lock: 'after\n', lockError: 'error: unable to download' }).handle,
  );

  const result = await stub.run([
    'docker',
    'run',
    '--rm',
    '-v',
    `${ctx.dir}:/src`,
    '-w',
    '/src',
    'example/nix:1.0.0',
    'sh',
    '-c',
    'nix flake lock',
  ]);

  expect({ exitCode: result.exitCode, stderr: result.stderr.toString() }).toStrictEqual({
    exitCode: 1,
    stderr: 'error: unable to download\n',
  });

  const lock = await readFile(join(ctx.dir, 'flake.lock'), 'utf8');

  expect(lock).toBe('before\n');
});

test('it leaves another docker call to the next handler', async () => {
  const stub = buildStubRunner(buildStubReleaseDocker({}).handle);

  const result = await stub.run(['docker', 'run', '--rm', 'alpine', 'true']);

  expect(result.exitCode).toBe(97);
});

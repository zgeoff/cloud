import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { loadTargetAgentImages, pullDeployedHostTag } from './load-target-agent-images.ts';
import { buildStubRunner } from './src/test-utils/build-stub-runner.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'load-target-agent-images-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  return { directory };
}

test('it reads the image of every atc target, of the NixOS file, and of the NixOS file at the commit the host runs', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.directory, 'config.json'),
    JSON.stringify({
      targets: { local: { provider: 'local' }, cloud: { image: 'agent-2f367d8' } },
    }),
  );

  await writeFile(
    join(ctx.directory, 'configuration.nix'),
    '        # image = "agent-0000000";\n        image = "agent-6106be2d";\n',
  );

  const stub = buildStubRunner(() => ({
    stdout: '        image = "agent-1";\n',
  }));

  const images = await loadTargetAgentImages(stub, {
    atcConfigs: [join(ctx.directory, 'config.json')],
    nix: { clone: ctx.directory, file: 'configuration.nix' },
  });

  expect(images).toStrictEqual(['agent-2f367d8', 'agent-6106be2d', 'agent-1']);

  expect(stub.calls.map((call) => call.argv)).toStrictEqual([
    ['git', '-C', ctx.directory, 'show', 'refs/tags/deployed/host:configuration.nix'],
  ]);
});

test('it names no image for a config file that does not exist', async () => {
  const ctx = await setupTest();

  const images = await loadTargetAgentImages(
    buildStubRunner(() => ({})),
    {
      atcConfigs: [join(ctx.directory, 'absent.json')],
      nix: { clone: '/clone', file: 'configuration.nix' },
    },
  );

  expect(images).toStrictEqual([]);
});

test('it throws for a config that is not JSON, so no image is guessed', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.directory, 'config.json'), 'not json');

  const loading = loadTargetAgentImages(
    buildStubRunner(() => ({})),
    {
      atcConfigs: [join(ctx.directory, 'config.json')],
      nix: { clone: '/clone', file: 'configuration.nix' },
    },
  );

  expect(loading).rejects.toThrow();
});

test('it throws when the NixOS file is missing at the deployed host tag', () => {
  const loading = loadTargetAgentImages(
    buildStubRunner(() => ({ exitCode: 128, stderr: 'fatal: not a git repository\n' })),
    { atcConfigs: [], nix: { clone: '/clone', file: 'configuration.nix' } },
  );

  expect(loading).rejects.toThrow(
    'git show of configuration.nix at deployed/host failed: fatal: not a git repository',
  );
});

test('it fetches the deployed host tag into the clone', async () => {
  const stub = buildStubRunner(() => ({}));

  await pullDeployedHostTag(stub, '/clone');

  expect(stub.calls.map((call) => call.argv)).toStrictEqual([
    [
      'git',
      '-C',
      '/clone',
      'fetch',
      '-q',
      'origin',
      '+refs/tags/deployed/host:refs/tags/deployed/host',
    ],
  ]);
});

test('it throws when the deployed host tag cannot be fetched', () => {
  const loading = pullDeployedHostTag(
    buildStubRunner(() => ({ exitCode: 128, stderr: "fatal: couldn't find remote ref\n" })),
    '/clone',
  );

  expect(loading).rejects.toThrow(
    "git fetch of deployed/host failed: fatal: couldn't find remote ref",
  );
});

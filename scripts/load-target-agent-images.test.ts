import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { loadTargetAgentImages } from './load-target-agent-images.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'load-target-agent-images-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  return { directory };
}

test('it reads the image of every atc target and of the NixOS target', async () => {
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

  const images = await loadTargetAgentImages({
    atcConfigs: [join(ctx.directory, 'config.json')],
    nixFiles: [join(ctx.directory, 'configuration.nix')],
  });

  expect(images).toStrictEqual(['agent-2f367d8', 'agent-6106be2d']);
});

test('it names no image for a file that is missing or is not JSON', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.directory, 'config.json'), 'not json');

  const images = await loadTargetAgentImages({
    atcConfigs: [join(ctx.directory, 'config.json'), join(ctx.directory, 'absent.json')],
    nixFiles: [join(ctx.directory, 'absent.nix')],
  });

  expect(images).toStrictEqual([]);
});

import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { loadCloudTarget } from './load-cloud-target.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'load-cloud-target-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  return { directory };
}

test('it loads the cloud target’s image and guest atc', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.directory, 'config.json'),
    '{"targets":{"cloud":{"provider":"imp","image":"agent-abc1234","guestATC":"/usr/local/bin/atc"}}}',
  );

  const target = await loadCloudTarget(join(ctx.directory, 'config.json'));

  expect(target).toStrictEqual({ image: 'agent-abc1234', guestATC: '/usr/local/bin/atc' });
});

test('it reads a field that is absent or not a string as unset', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.directory, 'config.json'), '{"targets":{"cloud":{"image":7}}}');

  const target = await loadCloudTarget(join(ctx.directory, 'config.json'));

  expect(target).toStrictEqual({ image: undefined, guestATC: undefined });
});

test.each([
  ['no targets', '{"port":8415}'],
  ['a cloud target that is a list', '{"targets":{"cloud":[]}}'],
  ['a cloud target that is null', '{"targets":{"cloud":null}}'],
  ['text that is not JSON', 'port = 8415'],
])('it refuses a config with %s', async (_label, text) => {
  const ctx = await setupTest();

  await writeFile(join(ctx.directory, 'config.json'), text);

  expect(loadCloudTarget(join(ctx.directory, 'config.json'))).rejects.toMatchObject({
    exitCode: 1,
    message: `${join(ctx.directory, 'config.json')} has no targets.cloud object`,
  });
});

test('it refuses a config that does not exist', async () => {
  const ctx = await setupTest();

  expect(loadCloudTarget(join(ctx.directory, 'config.json'))).rejects.toMatchObject({
    exitCode: 1,
    message: `${join(ctx.directory, 'config.json')} has no targets.cloud object`,
  });
});

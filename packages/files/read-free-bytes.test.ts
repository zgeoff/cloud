import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readFreeBytes } from './read-free-bytes.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'files-free-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  return { directory };
}

// df's Avail column is the space left to an unprivileged writer; other writers on the host move
// it between the two reads, so the reads agree within 64 MiB
test('it reads the space df reports as available on the filesystem that holds the path', async () => {
  const ctx = await setupTest();

  const df = Bun.spawnSync(['df', '--block-size=1', '--output=avail', ctx.directory]);
  const available = Number(df.stdout.toString().trim().split('\n').at(-1));

  expect(readFreeBytes(ctx.directory)).toBeWithin(available - 67_108_864, available + 67_108_864);
});

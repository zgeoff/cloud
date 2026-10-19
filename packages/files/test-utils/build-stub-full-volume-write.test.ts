import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildStubFullVolumeWrite } from './build-stub-full-volume-write.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'files-full-write-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  return { directory };
}

test('it rejects with the ENOSPC error of a full device', () => {
  const write = buildStubFullVolumeWrite();

  expect(write('/dev/null', new Blob(['bytes']))).rejects.toMatchObject({ code: 'ENOSPC' });
});

test('it leaves the first byte of the file at the path, as a write cut short does', async () => {
  const ctx = await setupTest();

  const write = buildStubFullVolumeWrite();
  const path = join(ctx.directory, 'part');

  await write(path, new Blob(['bytes'])).catch(() => null);

  const written = await readFile(path, 'utf8');

  expect(written).toBe('b');
});

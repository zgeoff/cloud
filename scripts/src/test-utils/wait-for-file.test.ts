import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { waitForFile } from './wait-for-file.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'wait-for-file-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  return { directory };
}

test('it resolves once a background writer fills a file that did not exist', async () => {
  const ctx = await setupTest();

  const path = join(ctx.directory, 'out');

  Bun.spawn(['bash', '-c', 'sleep 0.05; echo ready > "$1"', 'bash', path]);

  await waitForFile(path);

  const text = await readFile(path, 'utf8');

  expect(text).toBe('ready\n');
});

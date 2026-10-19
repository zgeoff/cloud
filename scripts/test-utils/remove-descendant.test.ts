import { expect, onTestFinished, test } from 'bun:test';
import { existsSync } from 'node:fs';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { removeDescendant } from './remove-descendant.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'remove-descendant-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  return { directory };
}

test('it kills the process that the pid file names and removes the directory', async () => {
  const ctx = await setupTest();

  const child = Bun.spawn(['sleep', '30']);

  onTestFinished(() => {
    child.kill('SIGKILL');
  });

  await writeFile(join(ctx.directory, 'pid'), `${child.pid}\n`);
  await removeDescendant(ctx.directory, join(ctx.directory, 'pid'));
  await child.exited;

  expect(child.signalCode).toBe('SIGKILL');
  expect(existsSync(ctx.directory)).toBe(false);
});

test('it removes the directory when the command never wrote its pid', async () => {
  const ctx = await setupTest();

  await removeDescendant(ctx.directory, join(ctx.directory, 'pid'));

  expect(existsSync(ctx.directory)).toBe(false);
});

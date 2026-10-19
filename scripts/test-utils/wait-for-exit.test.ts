import { expect, onTestFinished, test } from 'bun:test';
import { existsSync } from 'node:fs';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { waitForExit } from './wait-for-exit.ts';
import { waitForFile } from './wait-for-file.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'wait-for-exit-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  return { directory };
}

test('it reports a child that exits under a parent that never reaps it as exited', async () => {
  const ctx = await setupTest();

  const pidFile = join(ctx.directory, 'pid');

  // the background sleep ends under the exec'd sleep, which never reaps it, so it stays a zombie
  const parent = Bun.spawn([
    'bash',
    '-c',
    'sleep 0.05 & echo $! > "$1"; exec sleep 30',
    'bash',
    pidFile,
  ]);

  onTestFinished(() => {
    parent.kill('SIGKILL');
  });

  await waitForFile(pidFile);

  const text = await readFile(pidFile, 'utf8');

  const pid = Number(text);

  const isExited = await waitForExit(pid);

  expect(isExited).toBe(true);
  expect(existsSync(`/proc/${pid}`)).toBe(true);
});

test('it reports a process that runs past its second as running', async () => {
  const child = Bun.spawn(['sleep', '30']);

  onTestFinished(() => {
    child.kill('SIGKILL');
  });

  const isExited = await waitForExit(child.pid);

  expect(isExited).toBe(false);
});

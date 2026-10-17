import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createGitOrigin } from './create-git-origin.ts';

async function setupTest() {
  const dir = await mkdtemp(join(tmpdir(), 'create-git-origin-'));

  onTestFinished(() => rm(dir, { recursive: true, force: true }));

  return { dir };
}

test('it creates a seed whose pushes reach the bare origin on main', async () => {
  const ctx = await setupTest();
  const repo = await createGitOrigin(ctx.dir);

  await writeFile(join(repo.seed, 'README'), 'seed\n');

  await repo.git(['-C', repo.seed, 'add', '-A']);
  await repo.git(['-C', repo.seed, 'commit', '-qm', 'seed']);
  await repo.git(['-C', repo.seed, 'push', '-q', 'origin', 'main']);

  const seedHead = await repo.git(['-C', repo.seed, 'rev-parse', 'HEAD']);
  const origin = await repo.git(['-C', repo.origin, 'log', '-1', '--format=%H %an <%ae>', 'main']);

  expect(origin).toBe(`${seedHead} test <test@example.invalid>`);
});

test('it runs git without the user’s global config', async () => {
  const ctx = await setupTest();
  const repo = await createGitOrigin(ctx.dir);

  expect(repo.env).toContainEntries([
    ['GIT_CONFIG_GLOBAL', '/dev/null'],
    ['GIT_CONFIG_NOSYSTEM', '1'],
    ['HOME', join(ctx.dir, 'home')],
  ]);
});

test('it turns off auto maintenance in the origin, the seed and a clone', async () => {
  const ctx = await setupTest();
  const repo = await createGitOrigin(ctx.dir);

  const clone = join(ctx.dir, 'clone');

  await repo.git(['clone', '-q', repo.origin, clone]);

  // the origin's own config, which a push to it reads without the GIT_CONFIG_* variables
  const settings = await Promise.all([
    repo.git(['-C', repo.origin, 'config', '--local', '--get', 'maintenance.auto']),
    repo.git(['-C', repo.seed, 'config', '--get', 'maintenance.auto']),
    repo.git(['-C', clone, 'config', '--get', 'maintenance.auto']),
  ]);

  expect(settings).toStrictEqual(['false', 'false', 'false']);
});

test('it throws with git’s message when a git call fails', async () => {
  const ctx = await setupTest();
  const repo = await createGitOrigin(ctx.dir);

  expect(repo.git(['-C', repo.seed, 'rev-parse', '--verify', 'nowhere'])).rejects.toThrow(
    `git -C ${repo.seed} rev-parse --verify nowhere exited 128: fatal: Needed a single revision\n`,
  );
});

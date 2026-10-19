import { expect, onTestFinished, test } from 'bun:test';
import { writeFileSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { $ } from 'bun';
import { collectBranchFiles } from './collect-branch-files.ts';

test('it lists the files a new branch with no upstream changes', async () => {
  const ctx = await setupTest();

  await $`git switch --quiet -c feature`.env(ctx.env).cwd(ctx.repo).quiet();

  writeFileSync(join(ctx.repo, 'a.ts'), 'a');
  writeFileSync(join(ctx.repo, 'b.ts'), 'b');

  await $`git add -A`.env(ctx.env).cwd(ctx.repo).quiet();
  await $`git commit --quiet -m feature`.env(ctx.env).cwd(ctx.repo).quiet();

  const files = await collectBranchFiles({ cwd: ctx.repo, env: ctx.env });

  expect(files.toSorted()).toStrictEqual(['a.ts', 'b.ts']);
});

test('it lists only the branch files once the branch is pushed with an upstream', async () => {
  const ctx = await setupTest();

  await $`git switch --quiet -c feature`.env(ctx.env).cwd(ctx.repo).quiet();

  writeFileSync(join(ctx.repo, 'a.ts'), 'a');

  await $`git add -A`.env(ctx.env).cwd(ctx.repo).quiet();
  await $`git commit --quiet -m feature`.env(ctx.env).cwd(ctx.repo).quiet();
  await $`git push --quiet -u origin feature`.env(ctx.env).cwd(ctx.repo).quiet();

  const files = await collectBranchFiles({ cwd: ctx.repo, env: ctx.env });

  expect(files).toStrictEqual(['a.ts']);
});

test('it lists nothing when the branch has no commits of its own', async () => {
  const ctx = await setupTest();

  await $`git switch --quiet -c feature`.env(ctx.env).cwd(ctx.repo).quiet();

  const files = await collectBranchFiles({ cwd: ctx.repo, env: ctx.env });

  expect(files).toStrictEqual([]);
});

test('it leaves out a file the branch deleted', async () => {
  const ctx = await setupTest();

  await $`git switch --quiet -c feature`.env(ctx.env).cwd(ctx.repo).quiet();
  await $`git rm --quiet README.md`.env(ctx.env).cwd(ctx.repo).quiet();

  writeFileSync(join(ctx.repo, 'a.ts'), 'a');

  await $`git add -A`.env(ctx.env).cwd(ctx.repo).quiet();
  await $`git commit --quiet -m feature`.env(ctx.env).cwd(ctx.repo).quiet();

  const files = await collectBranchFiles({ cwd: ctx.repo, env: ctx.env });

  expect(files).toStrictEqual(['a.ts']);
});

test('it falls back to origin/main when origin/HEAD is unset', async () => {
  const ctx = await setupTest();

  await $`git remote set-head origin --delete`.env(ctx.env).cwd(ctx.repo).quiet();
  await $`git switch --quiet -c feature`.env(ctx.env).cwd(ctx.repo).quiet();

  writeFileSync(join(ctx.repo, 'a.ts'), 'a');

  await $`git add -A`.env(ctx.env).cwd(ctx.repo).quiet();
  await $`git commit --quiet -m feature`.env(ctx.env).cwd(ctx.repo).quiet();

  const files = await collectBranchFiles({ cwd: ctx.repo, env: ctx.env });

  expect(files).toStrictEqual(['a.ts']);
});

test('it rejects a repository with no origin', async () => {
  const ctx = await setupTest();

  await $`git remote remove origin`.env(ctx.env).cwd(ctx.repo).quiet();

  expect(collectBranchFiles({ cwd: ctx.repo, env: ctx.env })).rejects.toThrowWithMessage(
    Error,
    /cannot find the base of this branch/u,
  );
});

test('it exits non-zero with a message when run in a repository with no origin', async () => {
  const ctx = await setupTest();

  await $`git remote remove origin`.env(ctx.env).cwd(ctx.repo).quiet();

  const run = Bun.spawnSync([process.execPath, join(import.meta.dir, 'collect-branch-files.ts')], {
    cwd: ctx.repo,
    env: ctx.env,
  });

  expect(run.exitCode).toBe(1);

  expect(run.stderr.toString()).toStartWith(
    'collect-branch-files: cannot find the base of this branch',
  );
});

test('it lists nothing when the branch only deletes a file', async () => {
  const ctx = await setupTest();

  await $`git switch --quiet -c feature`.env(ctx.env).cwd(ctx.repo).quiet();
  await $`git rm --quiet README.md`.env(ctx.env).cwd(ctx.repo).quiet();
  await $`git commit --quiet -m remove`.env(ctx.env).cwd(ctx.repo).quiet();

  const files = await collectBranchFiles({ cwd: ctx.repo, env: ctx.env });

  expect(files).toStrictEqual([]);
});

test('it lists a deleted file when deletions are included', async () => {
  const ctx = await setupTest();

  await $`git switch --quiet -c feature`.env(ctx.env).cwd(ctx.repo).quiet();
  await $`git rm --quiet README.md`.env(ctx.env).cwd(ctx.repo).quiet();
  await $`git commit --quiet -m remove`.env(ctx.env).cwd(ctx.repo).quiet();

  const files = await collectBranchFiles({ cwd: ctx.repo, env: ctx.env, includeDeleted: true });

  expect(files).toStrictEqual(['README.md']);
});

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'collect-branch-files-'));

  onTestFinished(async () => {
    await rm(directory, { recursive: true, force: true });
  });

  // strips GIT_* and host git config, so the fixture never reads the repository running the test
  const env = {
    ...Object.fromEntries(
      Object.entries(process.env).filter(
        ([name]: readonly [string, string | undefined]) => !name.startsWith('GIT_'),
      ),
    ),
    GIT_CONFIG_NOSYSTEM: '1',
    GIT_CONFIG_GLOBAL: '/dev/null',
  };

  const upstream = join(directory, 'upstream.git');
  const repo = join(directory, 'work');

  // no auto maintenance in either repository: a commit's or a push's detached repack could still
  // write into it while the test's cleanup removes it
  await $`git init --quiet --bare --template= --initial-branch=main ${upstream} && git clone --quiet --template= ${upstream} ${repo}`
    .env(env)
    .quiet();

  await $`git config maintenance.auto false`.env(env).cwd(upstream).quiet();

  await $`git config user.name cloud && git config user.email cloud@example.com && git config commit.gpgsign false && git config tag.gpgsign false && git config maintenance.auto false`
    .env(env)
    .cwd(repo)
    .quiet();

  writeFileSync(join(repo, 'README.md'), 'hello\n');

  await $`git add README.md && git commit --quiet -m initial && git push --quiet origin main && git remote set-head origin main`
    .env(env)
    .cwd(repo)
    .quiet();

  return { repo, env };
}

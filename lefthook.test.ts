import { expect, onTestFinished, test } from 'bun:test';
import { copyFileSync, readFileSync, writeFileSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { $ } from 'bun';

test('it runs lint:sh and test:scripts before a force-push of a shell change rebased onto a moved main', async () => {
  const ctx = await setupTest();

  await $`git switch --quiet -c feature`.env(ctx.env).cwd(ctx.repo).quiet();

  writeFileSync(join(ctx.repo, 'deploy.sh'), 'echo deploy\n');

  await $`git add -A && git commit --quiet -m feature && git push --quiet -u origin feature`
    .env(ctx.env)
    .cwd(ctx.repo)
    .quiet();

  await $`git switch --quiet main`.env(ctx.env).cwd(ctx.repo).quiet();

  writeFileSync(join(ctx.repo, 'notes.md'), 'moved\n');

  await $`git add -A && git commit --quiet -m moved && git push --quiet origin main && git switch --quiet feature && git rebase --quiet main`
    .env(ctx.env)
    .cwd(ctx.repo)
    .quiet();

  await $`${ctx.lefthook} run pre-push`.env(ctx.env).cwd(ctx.repo).quiet();

  expect(readFileSync(ctx.ranLog, 'utf8')).toBe(
    'format:check\nlint:sh\ncheck:pulumi-pins\ncheck:topology\ntypecheck\ntest:scripts\n',
  );
});

test('it skips the shell jobs before a force-push of a rebased branch whose moved main changed a shell file', async () => {
  const ctx = await setupTest();

  await $`git switch --quiet -c feature`.env(ctx.env).cwd(ctx.repo).quiet();

  writeFileSync(join(ctx.repo, 'notes.md'), 'feature\n');

  await $`git add -A && git commit --quiet -m feature && git push --quiet -u origin feature`
    .env(ctx.env)
    .cwd(ctx.repo)
    .quiet();

  await $`git switch --quiet main`.env(ctx.env).cwd(ctx.repo).quiet();

  writeFileSync(join(ctx.repo, 'deploy.sh'), 'echo deploy\n');

  await $`git add -A && git commit --quiet -m moved && git push --quiet origin main && git switch --quiet feature && git rebase --quiet main`
    .env(ctx.env)
    .cwd(ctx.repo)
    .quiet();

  await $`${ctx.lefthook} run pre-push`.env(ctx.env).cwd(ctx.repo).quiet();

  expect(readFileSync(ctx.ranLog, 'utf8')).toBe(
    'format:check\ncheck:pulumi-pins\ncheck:topology\ntypecheck\n',
  );
});

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'lefthook-'));

  onTestFinished(async () => {
    await rm(directory, { recursive: true, force: true });
  });

  // strips GIT_* and host git config, so the fixture never reads the repository running the test,
  // and LEFTHOOK_*, so a caller's lefthook settings never change which jobs run
  const env = {
    ...Object.fromEntries(
      Object.entries(process.env).filter(
        ([name]: readonly [string, string | undefined]) =>
          !name.startsWith('GIT_') && !name.startsWith('LEFTHOOK'),
      ),
    ),
    GIT_CONFIG_NOSYSTEM: '1',
    GIT_CONFIG_GLOBAL: '/dev/null',
  };

  const upstream = join(directory, 'upstream.git');
  const repo = join(directory, 'work');
  const ranLog = join(directory, 'ran.log');

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

  copyFileSync(join(import.meta.dir, 'lefthook.yml'), join(repo, 'lefthook.yml'));

  // each script a pre-push job runs records its name; files:branch is the real one
  const recorders = [
    'format:check',
    'lint:files',
    'lint:sh',
    'lint:nix',
    'lint:py',
    'lint:actions',
    'check:pulumi-pins',
    'check:topology',
    'typecheck',
    'test:related',
    'test:scripts',
    'provider:check',
    'check:sdk',
  ].map((name) => [name, `echo ${name} >> ${ranLog}`]);

  writeFileSync(
    join(repo, 'package.json'),
    `${JSON.stringify({
      scripts: {
        'files:branch': `bun ${join(import.meta.dir, 'scripts', 'read-branch-files.ts')}`,
        ...Object.fromEntries(recorders),
      },
    })}\n`,
  );

  await $`git add -A && git commit --quiet -m initial && git push --quiet origin main && git remote set-head origin main`
    .env(env)
    .cwd(repo)
    .quiet();

  return { repo, env, ranLog, lefthook: join(import.meta.dir, 'node_modules', '.bin', 'lefthook') };
}

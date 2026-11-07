import { expect, onTestFinished, test } from 'bun:test';
import { copyFileSync, mkdirSync, readFileSync, symlinkSync, writeFileSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { $ } from 'bun';
import { z } from 'zod';

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

test('it passes the lint job before a push whose only TypeScript file is one oxlint ignores', async () => {
  const ctx = await setupTest();

  await $`git switch --quiet -c feature`.env(ctx.env).cwd(ctx.repo).quiet();

  const scriptsSchema = z.object({ scripts: z.record(z.string(), z.string()) });
  const fixtureText = readFileSync(join(ctx.repo, 'package.json'), 'utf8');
  const repoText = readFileSync(join(import.meta.dir, 'package.json'), 'utf8');
  const fixture = scriptsSchema.parse(JSON.parse(fixtureText));
  const lintFiles = scriptsSchema.parse(JSON.parse(repoText)).scripts['lint:files'];

  writeFileSync(
    join(ctx.repo, 'package.json'),
    `${JSON.stringify({
      scripts: {
        ...fixture.scripts,
        'lint:files': `sh -c '${lintFiles} "$@" && echo lint:files >> ${ctx.ranLog}' lint:files`,
      },
    })}\n`,
  );

  copyFileSync(join(import.meta.dir, '.oxlintrc.json'), join(ctx.repo, '.oxlintrc.json'));
  symlinkSync(join(import.meta.dir, 'node_modules'), join(ctx.repo, 'node_modules'));
  writeFileSync(join(ctx.repo, '.gitignore'), 'node_modules\n');
  mkdirSync(join(ctx.repo, '.claude/hooks'), { recursive: true });
  writeFileSync(join(ctx.repo, '.claude/hooks/start.ts'), 'export {};\n');

  await $`git add -A && git commit --quiet -m feature && git push --quiet -u origin feature`
    .env(ctx.env)
    .cwd(ctx.repo)
    .quiet();

  const result = await $`${ctx.lefthook} run pre-push`.env(ctx.env).cwd(ctx.repo).nothrow().quiet();

  expect({ exitCode: result.exitCode, ran: readFileSync(ctx.ranLog, 'utf8') }).toStrictEqual({
    exitCode: 0,
    ran: 'lint:files\ntest:related .claude/hooks/start.ts\n',
  });
});

test('it leaves out each baseline job that one of its own pre-push jobs replaces', async () => {
  const ctx = await setupTest();

  await $`git switch --quiet -c feature`.env(ctx.env).cwd(ctx.repo).quiet();

  copyFileSync(join(import.meta.dir, 'lefthook.yml'), join(ctx.repo, 'lefthook.yml'));
  symlinkSync(join(import.meta.dir, 'node_modules'), join(ctx.repo, 'node_modules'));
  writeFileSync(join(ctx.repo, '.gitignore'), 'node_modules\n');

  await $`git add -A && git commit --quiet -m feature && git push --quiet -u origin feature`
    .env(ctx.env)
    .cwd(ctx.repo)
    .quiet();

  const result = await $`${ctx.lefthook} run pre-push 2>&1`
    .env(ctx.env)
    .cwd(ctx.repo)
    .nothrow()
    .quiet();

  const output = Bun.stripANSI(result.text());

  const excluded = [...output.matchAll(/(?<job>chex-\S+) \(skip\) name$/gmu)].map(
    (match) => match.groups?.job,
  );

  expect({ exitCode: result.exitCode, excluded }).toStrictEqual({
    exitCode: 0,
    excluded: [
      'chex-format:check',
      'chex-lint',
      'chex-shell',
      'chex-workflows',
      'chex-typecheck',
      'chex-test',
    ],
  });
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

  const jobSchema = z.looseObject({ name: z.string() });
  const hookSchema = z.looseObject({ jobs: z.array(jobSchema) });
  const configSchema = z.looseObject({ 'pre-commit': hookSchema, 'pre-push': hookSchema });
  const configText = readFileSync(join(import.meta.dir, 'lefthook.yml'), 'utf8');
  const { extends: _, ...config } = configSchema.parse(Bun.YAML.parse(configText));

  const keepOwnJobs = (hook: z.infer<typeof hookSchema>) => ({
    ...hook,
    jobs: hook.jobs.filter((job) => job.name !== 'chex-baseline'),
  });

  // the chex baseline and its guard read node_modules, which the fixture lacks, so it keeps cloud's
  // own jobs
  writeFileSync(
    join(repo, 'lefthook.yml'),
    Bun.YAML.stringify({
      ...config,
      'pre-commit': keepOwnJobs(config['pre-commit']),
      'pre-push': keepOwnJobs(config['pre-push']),
    }),
  );

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
  ].map((name): [string, string] => [name, `echo ${name} >> ${ranLog}`]);

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

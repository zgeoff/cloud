import { expect, mock, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, readFile, readdir, rename, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildRealProgramHandler } from '../test-utils/build-real-program-handler.ts';
import { buildStubRunner } from '../test-utils/build-stub-runner.ts';
import { createGitOrigin } from '../test-utils/create-git-origin.ts';
import { runWorkflowLint } from './run-workflow-lint.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'run-workflow-lint-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const tools = await createGitOrigin(join(directory, 'tools'));

  const root = join(directory, 'repo');
  const cacheDirectory = join(directory, 'cache');

  await mkdir(join(root, '.github', 'workflows'), { recursive: true });
  await mkdir(cacheDirectory);
  await mkdir(join(tools.seed, 'packages', 'chex', 'src'), { recursive: true });

  const stub = buildStubRunner(buildRealProgramHandler(['git', process.execPath], tools.env));
  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  const dependencies = {
    run: stub.run,
    readText: (path: string) => readFile(path, 'utf8'),
    probeFile: (path: string) => Bun.file(path).exists(),
    removeTree: (path: string) => rm(path, { recursive: true, force: true }),
    renameTree: (from: string, to: string) => rename(from, to),
    printOut,
    printErr,
  };

  return { directory, tools, root, cacheDirectory, stub, printOut, printErr, dependencies };
}

test('it runs the lint at the tools tag that the repo-sync caller pins, in the repo', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, '.github', 'workflows', 'repo-sync.yml'),
    'jobs:\n  sync:\n    uses: zgeoff/tools/.github/workflows/repo-sync.yml@sync-v42\n',
  );

  await writeFile(
    join(ctx.tools.seed, 'packages', 'chex', 'src', 'run-workflows-check.ts'),
    "process.stdout.write('linted ' + process.cwd() + ' as ' + process.env['CHECKS_PROFILE'] + '\\n');\n",
  );

  await ctx.tools.git(['-C', ctx.tools.seed, 'add', '.']);
  await ctx.tools.git(['-C', ctx.tools.seed, 'commit', '-qm', 'add the lint']);
  await ctx.tools.git(['-C', ctx.tools.seed, 'tag', 'sync-v42']);
  await ctx.tools.git(['-C', ctx.tools.seed, 'push', '-q', 'origin', 'main', 'sync-v42']);

  const status = await runWorkflowLint({
    root: ctx.root,
    toolsURL: `file://${ctx.tools.origin}`,
    cacheDirectory: ctx.cacheDirectory,
    env: { ...ctx.tools.env, CHECKS_PROFILE: 'public' },
    ...ctx.dependencies,
  });

  const kept = await readdir(ctx.cacheDirectory);

  expect(status).toBe(0);
  expect(ctx.printOut.mock.calls).toStrictEqual([[`linted ${ctx.root} as public\n`]]);
  expect(kept).toStrictEqual(['chex-sync-v42']);
});

test('it checks out the lint again beside a kept checkout that holds only sync/pre-push', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, '.github', 'workflows', 'repo-sync.yml'),
    'jobs:\n  sync:\n    uses: zgeoff/tools/.github/workflows/repo-sync.yml@sync-v42\n',
  );

  await writeFile(
    join(ctx.tools.seed, 'packages', 'chex', 'src', 'run-workflows-check.ts'),
    "process.stdout.write('linted from the chex checkout\\n');\n",
  );

  await ctx.tools.git(['-C', ctx.tools.seed, 'add', '.']);
  await ctx.tools.git(['-C', ctx.tools.seed, 'commit', '-qm', 'add the lint']);
  await ctx.tools.git(['-C', ctx.tools.seed, 'tag', 'sync-v42']);
  await ctx.tools.git(['-C', ctx.tools.seed, 'push', '-q', 'origin', 'main', 'sync-v42']);

  await mkdir(join(ctx.cacheDirectory, 'sync-v42', 'sync', 'pre-push'), { recursive: true });

  const status = await runWorkflowLint({
    root: ctx.root,
    toolsURL: `file://${ctx.tools.origin}`,
    cacheDirectory: ctx.cacheDirectory,
    env: ctx.tools.env,
    ...ctx.dependencies,
  });

  expect(status).toBe(0);
  expect(ctx.printOut.mock.calls).toStrictEqual([['linted from the chex checkout\n']]);
});

test('it runs the lint at the tools commit that the repo-sync caller pins with a main comment', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.tools.seed, 'packages', 'chex', 'src', 'run-workflows-check.ts'),
    "process.stdout.write('linted at the pinned commit\\n');\n",
  );

  await ctx.tools.git(['-C', ctx.tools.seed, 'add', '.']);
  await ctx.tools.git(['-C', ctx.tools.seed, 'commit', '-qm', 'add the lint']);

  const head = await ctx.tools.git(['-C', ctx.tools.seed, 'rev-parse', 'HEAD']);

  const pinned = head.trim();

  await writeFile(
    join(ctx.tools.seed, 'packages', 'chex', 'src', 'run-workflows-check.ts'),
    "process.stdout.write('linted at a newer commit\\n');\n",
  );

  await ctx.tools.git(['-C', ctx.tools.seed, 'commit', '-qam', 'change the lint']);
  await ctx.tools.git(['-C', ctx.tools.seed, 'push', '-q', 'origin', 'main']);

  await writeFile(
    join(ctx.root, '.github', 'workflows', 'repo-sync.yml'),
    `jobs:\n  sync:\n    uses: zgeoff/tools/.github/workflows/repo-sync.yml@${pinned} # main\n`,
  );

  const status = await runWorkflowLint({
    root: ctx.root,
    toolsURL: `file://${ctx.tools.origin}`,
    cacheDirectory: ctx.cacheDirectory,
    env: ctx.tools.env,
    ...ctx.dependencies,
  });

  const kept = await readdir(ctx.cacheDirectory);

  expect(status).toBe(0);
  expect(ctx.printOut.mock.calls).toStrictEqual([['linted at the pinned commit\n']]);
  expect(kept).toStrictEqual([`chex-${pinned}`]);
});

test('it reuses the checkout of a tag it already holds, and runs no git', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, '.github', 'workflows', 'repo-sync.yml'),
    'jobs:\n  sync:\n    uses: zgeoff/tools/.github/workflows/repo-sync.yml@sync-v42\n',
  );

  await mkdir(join(ctx.cacheDirectory, 'chex-sync-v42', 'packages', 'chex', 'src'), {
    recursive: true,
  });

  await writeFile(
    join(ctx.cacheDirectory, 'chex-sync-v42', 'packages', 'chex', 'src', 'run-workflows-check.ts'),
    "process.stdout.write('linted from the kept checkout\\n');\n",
  );

  const status = await runWorkflowLint({
    root: ctx.root,
    toolsURL: `file://${ctx.tools.origin}`,
    cacheDirectory: ctx.cacheDirectory,
    env: ctx.tools.env,
    ...ctx.dependencies,
  });

  expect(status).toBe(0);
  expect(ctx.printOut.mock.calls).toStrictEqual([['linted from the kept checkout\n']]);
  expect(ctx.stub.calls.map((call) => call.argv[0])).toStrictEqual([process.execPath]);
});

test("it passes the lint's error status and output through", async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, '.github', 'workflows', 'repo-sync.yml'),
    'jobs:\n  sync:\n    uses: zgeoff/tools/.github/workflows/repo-sync.yml@sync-v42\n',
  );

  await mkdir(join(ctx.cacheDirectory, 'chex-sync-v42', 'packages', 'chex', 'src'), {
    recursive: true,
  });

  await writeFile(
    join(ctx.cacheDirectory, 'chex-sync-v42', 'packages', 'chex', 'src', 'run-workflows-check.ts'),
    "process.stderr.write('workflows: git show failed\\n');\nprocess.exitCode = 2;\n",
  );

  const status = await runWorkflowLint({
    root: ctx.root,
    toolsURL: `file://${ctx.tools.origin}`,
    cacheDirectory: ctx.cacheDirectory,
    env: ctx.tools.env,
    ...ctx.dependencies,
  });

  expect(status).toBe(2);
  expect(ctx.printErr.mock.calls).toStrictEqual([['workflows: git show failed\n']]);
});

test('it fails when the repo-sync caller pins no tools ref', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, '.github', 'workflows', 'repo-sync.yml'),
    'jobs:\n  sync:\n    runs-on: ubuntu-latest\n',
  );

  const status = await runWorkflowLint({
    root: ctx.root,
    toolsURL: `file://${ctx.tools.origin}`,
    cacheDirectory: ctx.cacheDirectory,
    env: ctx.tools.env,
    ...ctx.dependencies,
  });

  expect(status).toBe(2);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    [
      'run-workflow-lint: .github/workflows/repo-sync.yml calls no zgeoff/tools workflow at a ref\n',
    ],
  ]);

  expect(ctx.stub.calls).toStrictEqual([]);
});

test('it fails with git s error for a tag tools lacks, and keeps no partial checkout', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, '.github', 'workflows', 'repo-sync.yml'),
    'jobs:\n  sync:\n    uses: zgeoff/tools/.github/workflows/repo-sync.yml@sync-v43\n',
  );

  await writeFile(join(ctx.tools.seed, 'README.md'), 'tools\n');

  await ctx.tools.git(['-C', ctx.tools.seed, 'add', '.']);
  await ctx.tools.git(['-C', ctx.tools.seed, 'commit', '-qm', 'start']);
  await ctx.tools.git(['-C', ctx.tools.seed, 'push', '-q', 'origin', 'main']);

  const status = await runWorkflowLint({
    root: ctx.root,
    toolsURL: `file://${ctx.tools.origin}`,
    cacheDirectory: ctx.cacheDirectory,
    env: ctx.tools.env,
    ...ctx.dependencies,
  });

  const kept = await readdir(ctx.cacheDirectory);

  expect(status).toBe(1);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    [
      expect.toSatisfy(
        (text: string) =>
          text.startsWith('run-workflow-lint: cannot check out zgeoff/tools sync-v43: ') &&
          text.includes('sync-v43'),
      ),
    ],
  ]);

  expect(kept).toStrictEqual([]);
});

test("it leaves the pushing repo's HEAD and config alone when a worktree's pre-push hook runs it", async () => {
  const ctx = await setupTest();

  const pushing = join(ctx.directory, 'pushing');
  const worktree = join(ctx.directory, 'worktree');

  await writeFile(
    join(ctx.tools.seed, 'packages', 'chex', 'src', 'run-workflows-check.ts'),
    "process.stdout.write('linted the worktree\\n');\n",
  );

  await ctx.tools.git(['-C', ctx.tools.seed, 'add', '.']);
  await ctx.tools.git(['-C', ctx.tools.seed, 'commit', '-qm', 'add the lint']);
  await ctx.tools.git(['-C', ctx.tools.seed, 'tag', 'sync-v42']);
  await ctx.tools.git(['-C', ctx.tools.seed, 'push', '-q', 'origin', 'main', 'sync-v42']);
  await ctx.tools.git(['init', '-q', '-b', 'main', pushing]);
  await ctx.tools.git(['-C', pushing, 'config', 'maintenance.auto', 'false']);

  await mkdir(join(pushing, '.github', 'workflows'), { recursive: true });

  await writeFile(
    join(pushing, '.github', 'workflows', 'repo-sync.yml'),
    'jobs:\n  sync:\n    uses: zgeoff/tools/.github/workflows/repo-sync.yml@sync-v42\n',
  );

  await ctx.tools.git(['-C', pushing, 'add', '.']);
  await ctx.tools.git(['-C', pushing, 'commit', '-qm', 'add the repo-sync caller']);
  await ctx.tools.git(['-C', pushing, 'worktree', 'add', '-q', '-b', 'feature', worktree]);

  const readRepoState = async () => ({
    head: await ctx.tools.git(['-C', worktree, 'rev-parse', '--abbrev-ref', 'HEAD']),
    config: await readFile(join(pushing, '.git', 'config'), 'utf8'),
    hasWorktreeConfig: await Bun.file(join(pushing, '.git', 'config.worktree')).exists(),
  });

  const before = await readRepoState();

  // git exports these two to a hook that a push from a worktree runs
  const hookEnv = {
    ...ctx.tools.env,
    GIT_DIR: join(pushing, '.git', 'worktrees', 'worktree'),
    GIT_PREFIX: '',
  };

  const status = await runWorkflowLint({
    root: worktree,
    toolsURL: `file://${ctx.tools.origin}`,
    cacheDirectory: ctx.cacheDirectory,
    env: hookEnv,
    ...ctx.dependencies,
  });

  const after = await readRepoState();

  expect(status).toBe(0);
  expect(ctx.printOut.mock.calls).toStrictEqual([['linted the worktree\n']]);
  expect(after).toStrictEqual(before);
});

test("it runs the checkout's git without the caller's repository variables, and the lint with them", async () => {
  const ctx = await setupTest();

  const caller = join(ctx.directory, 'caller');

  await writeFile(
    join(ctx.root, '.github', 'workflows', 'repo-sync.yml'),
    'jobs:\n  sync:\n    uses: zgeoff/tools/.github/workflows/repo-sync.yml@sync-v42\n',
  );

  await writeFile(
    join(ctx.tools.seed, 'packages', 'chex', 'src', 'run-workflows-check.ts'),
    "process.stdout.write('linted\\n');\n",
  );

  await ctx.tools.git(['-C', ctx.tools.seed, 'add', '.']);
  await ctx.tools.git(['-C', ctx.tools.seed, 'commit', '-qm', 'add the lint']);
  await ctx.tools.git(['-C', ctx.tools.seed, 'tag', 'sync-v42']);
  await ctx.tools.git(['-C', ctx.tools.seed, 'push', '-q', 'origin', 'main', 'sync-v42']);

  const gitEnv = { ...ctx.tools.env, GIT_CONFIG_PARAMETERS: "'core.abbrev'='12'" };

  const callerEnv = {
    ...gitEnv,
    GIT_ALTERNATE_OBJECT_DIRECTORIES: join(caller, '.git', 'objects'),
    GIT_CONFIG: join(caller, '.git', 'config'),
    GIT_OBJECT_DIRECTORY: join(caller, '.git', 'objects'),
    GIT_DIR: join(caller, '.git'),
    GIT_WORK_TREE: caller,
    GIT_IMPLICIT_WORK_TREE: '0',
    GIT_GRAFT_FILE: join(caller, '.git', 'info', 'grafts'),
    GIT_INDEX_FILE: join(caller, '.git', 'index'),
    GIT_NO_REPLACE_OBJECTS: '1',
    GIT_REPLACE_REF_BASE: 'refs/replace/',
    GIT_PREFIX: 'scripts/',
    GIT_SHALLOW_FILE: join(caller, '.git', 'shallow'),
    GIT_COMMON_DIR: join(caller, '.git'),
  };

  await runWorkflowLint({
    root: ctx.root,
    toolsURL: `file://${ctx.tools.origin}`,
    cacheDirectory: ctx.cacheDirectory,
    env: callerEnv,
    ...ctx.dependencies,
  });

  expect(ctx.stub.calls.map((call) => [call.argv[0], call.options.env])).toStrictEqual([
    ['git', gitEnv],
    ['git', gitEnv],
    ['git', gitEnv],
    ['git', gitEnv],
    [process.execPath, callerEnv],
  ]);
});

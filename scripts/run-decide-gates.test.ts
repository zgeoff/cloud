import { expect, mock, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runDecideGates } from './run-decide-gates.ts';
import { runProcess } from './run-process.ts';
import { buildRealProgramHandler } from './test-utils/build-real-program-handler.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';
import { createGitOrigin } from './test-utils/create-git-origin.ts';

// Each test runs real git in its own repository, against a manifest it writes; the manifest's own
// gates are covered by needs-gate.test.ts.
async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'run-decide-gates-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const repo = await createGitOrigin(directory);

  const runner = buildStubRunner(buildRealProgramHandler(['git'], repo.env));
  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  return { directory, repo, runner, printOut, printErr };
}

test('it skips each gate whose paths no commit in the range changes', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.directory, 'gates.yml'),
    "gates:\n  lint:\n    paths: ['**']\n    ignore: ['**/*.md']\n  apply:\n    paths: [infra/**]\n",
  );

  await mkdir(join(ctx.repo.seed, 'infra'));
  await writeFile(join(ctx.repo.seed, 'infra', 'index.ts'), 'export {};\n');

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the program']);

  const base = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', 'HEAD']);

  await writeFile(join(ctx.repo.seed, 'README.md'), '# readme\n');

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the readme']);

  const exitCode = await runDecideGates({
    args: [base, 'HEAD', 'lint', 'apply'],
    cwd: ctx.repo.seed,
    manifestPath: join(ctx.directory, 'gates.yml'),
    githubOutput: undefined,
    githubStepSummary: undefined,
    run: ctx.runner.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(0);
  expect(ctx.printOut.mock.calls).toStrictEqual([['lint=false\napply=false\n']]);
  expect(ctx.printErr).not.toHaveBeenCalled();
});

test('it needs a gate for a change that a later commit in the range reverts', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.directory, 'gates.yml'), 'gates:\n  apply:\n    paths: [infra/**]\n');
  await writeFile(join(ctx.repo.seed, 'README.md'), '# readme\n');

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the readme']);

  const base = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', 'HEAD']);

  await mkdir(join(ctx.repo.seed, 'infra'));
  await writeFile(join(ctx.repo.seed, 'infra', 'index.ts'), 'export {};\n');

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the program']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'revert', '--no-edit', 'HEAD']);

  const exitCode = await runDecideGates({
    args: [base, 'HEAD', 'apply'],
    cwd: ctx.repo.seed,
    manifestPath: join(ctx.directory, 'gates.yml'),
    githubOutput: undefined,
    githubStepSummary: undefined,
    run: ctx.runner.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(0);
  expect(ctx.printOut.mock.calls).toStrictEqual([['apply=true\n']]);
});

test('it counts the old path of a file renamed out of the gate', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.directory, 'gates.yml'), 'gates:\n  apply:\n    paths: [infra/**]\n');
  await mkdir(join(ctx.repo.seed, 'infra'));
  await writeFile(join(ctx.repo.seed, 'infra', 'notes.md'), '# notes\n');

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the notes']);

  const base = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', 'HEAD']);

  await ctx.repo.git(['-C', ctx.repo.seed, 'mv', 'infra/notes.md', 'notes.md']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'move the notes']);

  const exitCode = await runDecideGates({
    args: [base, 'HEAD', 'apply'],
    cwd: ctx.repo.seed,
    manifestPath: join(ctx.directory, 'gates.yml'),
    githubOutput: undefined,
    githubStepSummary: undefined,
    run: ctx.runner.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(0);
  expect(ctx.printOut.mock.calls).toStrictEqual([['apply=true\n']]);
});

test('it counts the change a merge commit brings against its first parent', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.directory, 'gates.yml'), 'gates:\n  apply:\n    paths: [infra/**]\n');
  await writeFile(join(ctx.repo.seed, 'README.md'), '# readme\n');

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the readme']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'switch', '-qc', 'feature']);

  await mkdir(join(ctx.repo.seed, 'infra'));
  await writeFile(join(ctx.repo.seed, 'infra', 'index.ts'), 'export {};\n');

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the program']);

  const feature = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', 'HEAD']);

  await ctx.repo.git(['-C', ctx.repo.seed, 'switch', '-q', 'main']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'merge', '-q', '--no-ff', '-m', 'merge', 'feature']);

  const exitCode = await runDecideGates({
    args: [feature, 'HEAD', 'apply'],
    cwd: ctx.repo.seed,
    manifestPath: join(ctx.directory, 'gates.yml'),
    githubOutput: undefined,
    githubStepSummary: undefined,
    run: ctx.runner.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(0);
  expect(ctx.printOut.mock.calls).toStrictEqual([['apply=true\n']]);
});

test('it needs every gate for a base of all zeros', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.directory, 'gates.yml'),
    'gates:\n  apply:\n    paths: [infra/**]\n  go:\n    paths: [provider/**]\n',
  );

  await writeFile(join(ctx.repo.seed, 'README.md'), '# readme\n');

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the readme']);

  const exitCode = await runDecideGates({
    args: ['0'.repeat(40), 'HEAD', 'apply', 'go'],
    cwd: ctx.repo.seed,
    manifestPath: join(ctx.directory, 'gates.yml'),
    githubOutput: undefined,
    githubStepSummary: undefined,
    run: ctx.runner.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(0);
  expect(ctx.printOut.mock.calls).toStrictEqual([['apply=true\ngo=true\n']]);
});

test('it needs every gate for a base that is not an ancestor of the head', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.directory, 'gates.yml'), 'gates:\n  apply:\n    paths: [infra/**]\n');
  await writeFile(join(ctx.repo.seed, 'README.md'), '# readme\n');

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the readme']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'switch', '-qc', 'rewritten']);

  await writeFile(join(ctx.repo.seed, 'README.md'), '# rewritten\n');

  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qam', 'rewrite the readme']);

  const rewritten = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', 'HEAD']);

  await ctx.repo.git(['-C', ctx.repo.seed, 'switch', '-q', 'main']);

  await writeFile(join(ctx.repo.seed, 'NOTES.md'), '# notes\n');

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the notes']);

  const exitCode = await runDecideGates({
    args: [rewritten, 'HEAD', 'apply'],
    cwd: ctx.repo.seed,
    manifestPath: join(ctx.directory, 'gates.yml'),
    githubOutput: undefined,
    githubStepSummary: undefined,
    run: ctx.runner.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(0);
  expect(ctx.printOut.mock.calls).toStrictEqual([['apply=true\n']]);
});

test('it fails with git s error and status for a revision git cannot resolve', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.directory, 'gates.yml'), 'gates:\n  apply:\n    paths: [infra/**]\n');
  await writeFile(join(ctx.repo.seed, 'README.md'), '# readme\n');

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the readme']);

  const exitCode = await runDecideGates({
    args: ['deployed/prod', 'HEAD', 'apply'],
    cwd: ctx.repo.seed,
    manifestPath: join(ctx.directory, 'gates.yml'),
    githubOutput: undefined,
    githubStepSummary: undefined,
    run: ctx.runner.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(128);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['fatal: Not a valid object name deployed/prod\n'],
  ]);

  expect(ctx.printOut).not.toHaveBeenCalled();
});

test('it refuses a gate the manifest lacks', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.directory, 'gates.yml'), 'gates:\n  apply:\n    paths: [infra/**]\n');

  const exitCode = await runDecideGates({
    args: ['HEAD~1', 'HEAD', 'aply'],
    cwd: ctx.repo.seed,
    manifestPath: join(ctx.directory, 'gates.yml'),
    githubOutput: undefined,
    githubStepSummary: undefined,
    run: ctx.runner.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(2);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    [`run-decide-gates: ${join(ctx.directory, 'gates.yml')} has no gate aply\n`],
  ]);

  expect(ctx.runner.calls).toStrictEqual([]);
});

test('it refuses a call that names no gate', async () => {
  const ctx = await setupTest();

  const exitCode = await runDecideGates({
    args: ['HEAD~1', 'HEAD'],
    cwd: ctx.repo.seed,
    manifestPath: join(ctx.directory, 'gates.yml'),
    githubOutput: undefined,
    githubStepSummary: undefined,
    run: ctx.runner.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(2);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['usage: run-decide-gates.ts [--github] <base> <head> <gate>...\n'],
  ]);
});

test('it refuses an option it does not know, before any git call', async () => {
  const ctx = await setupTest();

  const exitCode = await runDecideGates({
    args: ['--gihtub', 'HEAD~1', 'HEAD', 'apply'],
    cwd: ctx.repo.seed,
    manifestPath: join(ctx.directory, 'gates.yml'),
    githubOutput: undefined,
    githubStepSummary: undefined,
    run: ctx.runner.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(2);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['usage: run-decide-gates.ts [--github] <base> <head> <gate>...\n'],
  ]);

  expect(ctx.runner.calls).toStrictEqual([]);
});

test('it needs no gate for an empty commit after the base', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.directory, 'gates.yml'),
    "gates:\n  full:\n    paths: ['**']\n    ignore: ['**/*.md']\n",
  );

  await writeFile(join(ctx.repo.seed, 'main.sh'), 'true\n');

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the script']);

  const base = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', 'HEAD']);

  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-q', '--allow-empty', '-m', 'retry CI']);

  const exitCode = await runDecideGates({
    args: [base, 'HEAD', 'full'],
    cwd: ctx.repo.seed,
    manifestPath: join(ctx.directory, 'gates.yml'),
    githubOutput: undefined,
    githubStepSummary: undefined,
    run: ctx.runner.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(0);
  expect(ctx.printOut.mock.calls).toStrictEqual([['full=false\n']]);
});

test('it reads --github after the positional arguments', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.directory, 'gates.yml'), 'gates:\n  apply:\n    paths: [infra/**]\n');
  await writeFile(join(ctx.directory, 'output'), '');
  await writeFile(join(ctx.directory, 'summary'), '');

  const exitCode = await runDecideGates({
    args: ['0'.repeat(40), 'HEAD', 'apply', '--github'],
    cwd: ctx.repo.seed,
    manifestPath: join(ctx.directory, 'gates.yml'),
    githubOutput: join(ctx.directory, 'output'),
    githubStepSummary: join(ctx.directory, 'summary'),
    run: ctx.runner.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const output = await readFile(join(ctx.directory, 'output'), 'utf8');

  expect(exitCode).toBe(0);
  expect(output).toBe('apply=true\n');
});

test('it fails on a manifest it cannot read, before any git call', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.directory, 'gates.yml'), 'gates:\n  apply:\n    path: [infra/**]\n');

  const exitCode = await runDecideGates({
    args: ['HEAD~1', 'HEAD', 'apply'],
    cwd: ctx.repo.seed,
    manifestPath: join(ctx.directory, 'gates.yml'),
    githubOutput: undefined,
    githubStepSummary: undefined,
    run: ctx.runner.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    [`run-decide-gates: ${join(ctx.directory, 'gates.yml')}: gate apply: unknown key path\n`],
  ]);

  expect(ctx.runner.calls).toStrictEqual([]);
});

test('it writes each answer to the step outputs, and each skipped line to the summary, with --github', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.directory, 'gates.yml'),
    [
      'gates:',
      '  lint:',
      '    skipped: Only Markdown files changed, so the linters did not run.',
      "    paths: ['**']",
      "    ignore: ['**/*.md']",
      '  go:',
      '    skipped: No Go file changed, so the Go checks did not run.',
      '    paths: [provider/**]',
      '',
    ].join('\n'),
  );

  await writeFile(join(ctx.directory, 'output'), 'earlier=1\n');
  await writeFile(join(ctx.directory, 'summary'), '# earlier\n');
  await writeFile(join(ctx.repo.seed, 'README.md'), '# readme\n');

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the readme']);

  const base = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', 'HEAD']);

  await writeFile(join(ctx.repo.seed, 'main.sh'), 'true\n');

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the script']);

  const exitCode = await runDecideGates({
    args: ['--github', base, 'HEAD', 'lint', 'go'],
    cwd: ctx.repo.seed,
    manifestPath: join(ctx.directory, 'gates.yml'),
    githubOutput: join(ctx.directory, 'output'),
    githubStepSummary: join(ctx.directory, 'summary'),
    run: ctx.runner.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const output = await readFile(join(ctx.directory, 'output'), 'utf8');
  const summary = await readFile(join(ctx.directory, 'summary'), 'utf8');

  expect(exitCode).toBe(0);
  expect(output).toBe('earlier=1\nlint=true\ngo=false\n');
  expect(summary).toBe('# earlier\nNo Go file changed, so the Go checks did not run.\n');

  expect(ctx.printOut.mock.calls).toStrictEqual([
    ['lint=true\ngo=false\n'],
    ['No Go file changed, so the Go checks did not run.\n'],
  ]);
});

test('it refuses --github without a step output file', async () => {
  const ctx = await setupTest();

  const exitCode = await runDecideGates({
    args: ['--github', 'HEAD~1', 'HEAD', 'lint'],
    cwd: ctx.repo.seed,
    manifestPath: join(ctx.directory, 'gates.yml'),
    githubOutput: undefined,
    githubStepSummary: join(ctx.directory, 'summary'),
    run: ctx.runner.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(2);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['run-decide-gates: --github needs GITHUB_OUTPUT\n'],
  ]);
});

test('it refuses --github without a step summary file', async () => {
  const ctx = await setupTest();

  const exitCode = await runDecideGates({
    args: ['--github', 'HEAD~1', 'HEAD', 'lint'],
    cwd: ctx.repo.seed,
    manifestPath: join(ctx.directory, 'gates.yml'),
    githubOutput: join(ctx.directory, 'output'),
    githubStepSummary: '',
    run: ctx.runner.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(2);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['run-decide-gates: --github needs GITHUB_STEP_SUMMARY\n'],
  ]);
});

// the real entry point, with the repo's manifest and the step files from its environment, as CI
// runs it
test('it skips the provider and full gates for a docs-only commit when run as the CLI with --github', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.directory, 'output'), '');
  await writeFile(join(ctx.directory, 'summary'), '');
  await mkdir(join(ctx.repo.seed, 'docs'));
  await writeFile(join(ctx.repo.seed, 'docs', 'guide.md'), '# guide\n');

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the guide']);

  const base = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', 'HEAD']);

  await writeFile(join(ctx.repo.seed, 'docs', 'guide.md'), '# guide\n\nRead the runbook.\n');

  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qam', 'extend the guide']);

  const result = await runProcess(
    [
      'bun',
      join(import.meta.dir, 'run-decide-gates.ts'),
      '--github',
      base,
      'HEAD',
      'provider',
      'full',
    ],
    {
      cwd: ctx.repo.seed,
      env: {
        ...ctx.repo.env,
        GITHUB_OUTPUT: join(ctx.directory, 'output'),
        GITHUB_STEP_SUMMARY: join(ctx.directory, 'summary'),
      },
    },
  );

  const output = await readFile(join(ctx.directory, 'output'), 'utf8');
  const summary = await readFile(join(ctx.directory, 'summary'), 'utf8');

  expect({
    exitCode: result.exitCode,
    stdout: result.stdout.toString(),
    stderr: result.stderr.toString(),
  }).toStrictEqual({
    exitCode: 0,
    stdout:
      'provider=false\nfull=false\n' +
      'No input of the provider checks changed, so the Go checks did not run.\n' +
      'Only Markdown files changed, so the Nix-image linters and the shell suites did not run.\n',
    stderr: '',
  });

  expect(output).toBe('provider=false\nfull=false\n');

  expect(summary).toBe(
    'No input of the provider checks changed, so the Go checks did not run.\n' +
      'Only Markdown files changed, so the Nix-image linters and the shell suites did not run.\n',
  );
});

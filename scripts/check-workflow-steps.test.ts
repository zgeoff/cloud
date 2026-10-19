import { expect, mock, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { checkWorkflowSteps } from './check-workflow-steps.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'check-workflow-steps-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  await mkdir(join(directory, '.github', 'workflows'), { recursive: true });

  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  return { directory, printOut, printErr };
}

test('it accepts workflows whose run steps are setup or one bun run call each', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.directory, 'package.json'),
    JSON.stringify({
      scripts: { 'ci:decide': 'bash scripts/decide.sh', drift: 'bun run preview' },
    }),
  );

  await writeFile(
    join(ctx.directory, '.github', 'workflows', 'ci.yml'),
    `jobs:
  ci:
    steps:
      - uses: actions/checkout@v7
      - name: Install
        run: bun install --frozen-lockfile
      - name: Decide
        env:
          BASE: \${{ github.event.before }}
        run: bun run --silent ci:decide "$BASE" 'main' HEAD~1
      - name: Drift
        run: |
          bun run drift -- --suppress-outputs
`,
  );

  await writeFile(
    join(ctx.directory, '.github', 'workflows', 'sync.yaml'),
    JSON.stringify({
      jobs: { sync: { uses: 'zgeoff/tools/.github/workflows/repo-sync.yml@main' } },
    }),
  );

  const exitCode = await checkWorkflowSteps({
    args: [ctx.directory],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(0);

  expect(ctx.printOut.mock.calls).toStrictEqual([
    ['check-workflow-steps: 3 run steps, each one bun run call\n'],
  ]);

  expect(ctx.printErr).not.toHaveBeenCalled();
});

test.each([
  ['an inline script', 'set -e\nbun run ci:decide', 'runs more than one line'],
  [
    'an expression interpolation',
    `bun run ci:decide "\${{ github.token }}"`,
    `interpolates a \${{ }} expression; pass it through env instead`,
  ],
  [
    'a pipe',
    'bun run ci:decide | tee -a "$GITHUB_STEP_SUMMARY"',
    'passes |, which is not a plain word, a quoted literal or one "$VARIABLE"',
  ],
  [
    'a command substitution',
    'bun run ci:decide "$(git rev-parse HEAD)"',
    'passes "$(git, which is not a plain word, a quoted literal or one "$VARIABLE"',
  ],
  [
    'an unquoted variable',
    'bun run ci:decide $BASE',
    'passes $BASE, which is not a plain word, a quoted literal or one "$VARIABLE"',
  ],
  [
    'a second command',
    'bun run ci:decide && bun run ci:decide',
    'passes &&, which is not a plain word, a quoted literal or one "$VARIABLE"',
  ],
  [
    'a command that is not bun run',
    'gh pr merge "$PR" --auto',
    'runs `gh pr merge "$PR" --auto`, not one bun run call',
  ],
  [
    'a bun call that is not bun run',
    'bun scripts/decide.ts',
    'runs `bun scripts/decide.ts`, not one bun run call',
  ],
  [
    'a script the root package.json does not define',
    'bun run ci:missing',
    'calls ci:missing, which the root package.json does not define',
  ],
])('it rejects a run step with %s', async (_label, run, reason) => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.directory, 'package.json'),
    JSON.stringify({ scripts: { 'ci:decide': 'bash scripts/decide.sh' } }),
  );

  await writeFile(
    join(ctx.directory, '.github', 'workflows', 'ci.yml'),
    JSON.stringify({ jobs: { ci: { steps: [{ name: 'Decide', run }] } } }),
  );

  const exitCode = await checkWorkflowSteps({
    args: [ctx.directory],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    [`.github/workflows/ci.yml: job ci, step "Decide": ${reason}\n`],
    ['check-workflow-steps: 1 of 1 run steps are not one bun run call\n'],
  ]);

  expect(ctx.printOut).not.toHaveBeenCalled();
});

test('it names every violation across files, jobs and unnamed steps, in file order', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.directory, 'package.json'),
    JSON.stringify({ scripts: { 'ci:decide': 'bash scripts/decide.sh' } }),
  );

  await writeFile(
    join(ctx.directory, '.github', 'workflows', 'b.yml'),
    JSON.stringify({
      jobs: {
        first: { steps: [{ uses: 'actions/checkout@v7' }, { run: 'echo one' }] },
        second: {
          steps: [
            { name: 'Fine', run: 'bun run ci:decide' },
            { name: 'Report', run: 'echo two' },
          ],
        },
      },
    }),
  );

  await writeFile(
    join(ctx.directory, '.github', 'workflows', 'a.yaml'),
    JSON.stringify({ jobs: { only: { steps: [{ run: 'sudo udevadm trigger' }] } } }),
  );

  await writeFile(join(ctx.directory, '.github', 'workflows', 'notes.txt'), 'run: echo ignored\n');

  const exitCode = await checkWorkflowSteps({
    args: [ctx.directory],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    [
      '.github/workflows/a.yaml: job only, step #1: runs `sudo udevadm trigger`, not one bun run call\n' +
        '.github/workflows/b.yml: job first, step #2: runs `echo one`, not one bun run call\n' +
        '.github/workflows/b.yml: job second, step "Report": runs `echo two`, not one bun run call\n',
    ],
    ['check-workflow-steps: 3 of 4 run steps are not one bun run call\n'],
  ]);

  expect(ctx.printOut).not.toHaveBeenCalled();
});

test('it rejects a second argument with its usage', async () => {
  const ctx = await setupTest();

  const exitCode = await checkWorkflowSteps({
    args: [ctx.directory, 'extra'],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(2);
  expect(ctx.printErr.mock.calls).toStrictEqual([['usage: check-workflow-steps.ts [repo root]\n']]);
  expect(ctx.printOut).not.toHaveBeenCalled();
});

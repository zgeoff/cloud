import { expect, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runActionsStep } from './run-actions-step.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'run-actions-step-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const workspace = join(directory, 'workspace');
  const files = join(directory, 'files');

  await mkdir(workspace);
  await mkdir(files);

  return { workspace, files };
}

test('it runs the step with the job s and the step s rendered env, and returns its outputs and summary', async () => {
  const ctx = await setupTest();

  const result = await runActionsStep({
    step: {
      run: 'echo "verdict=$VERDICT-$EVENT-$LEVEL" >> "$GITHUB_OUTPUT"; echo held | tee -a "$GITHUB_STEP_SUMMARY"',
      env: { VERDICT: `\${{ steps.guard.outputs.verdict }}`, LEVEL: 2 },
    },
    jobEnv: { EVENT: `\${{ github.event_name }}`, LEVEL: 1 },
    context: {
      github: { event_name: 'workflow_run' },
      inputs: {},
      steps: { guard: { outputs: { verdict: 'hold' } } },
    },
    cwd: ctx.workspace,
    directory: ctx.files,
    path: '/usr/bin:/bin',
  });

  expect(result).toStrictEqual({
    status: 'success',
    outputs: { verdict: 'hold-workflow_run-2' },
    stdout: 'held\n',
    summary: 'held\n',
  });
});

test('it stops at the first failed command and reports the step as failed', async () => {
  const ctx = await setupTest();

  const result = await runActionsStep({
    step: { run: 'false\necho "verdict=apply" >> "$GITHUB_OUTPUT"' },
    jobEnv: undefined,
    context: { github: {}, inputs: {}, steps: {} },
    cwd: ctx.workspace,
    directory: ctx.files,
    path: '/usr/bin:/bin',
  });

  expect(result).toStrictEqual({ status: 'failure', outputs: {}, stdout: '', summary: '' });
});

test('it runs the step in its working directory under the workspace', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.workspace, 'program'));

  const result = await runActionsStep({
    step: { run: 'echo "directory=$PWD" >> "$GITHUB_OUTPUT"', 'working-directory': 'program' },
    jobEnv: undefined,
    context: { github: {}, inputs: {}, steps: {} },
    cwd: ctx.workspace,
    directory: ctx.files,
    path: '/usr/bin:/bin',
  });

  expect(result.outputs).toStrictEqual({ directory: join(ctx.workspace, 'program') });
});

test('it rejects a step that runs an action', async () => {
  const ctx = await setupTest();

  expect(
    runActionsStep({
      step: { uses: 'actions/checkout@v7', run: 'true' },
      jobEnv: undefined,
      context: { github: {}, inputs: {}, steps: {} },
      cwd: ctx.workspace,
      directory: ctx.files,
      path: '/usr/bin:/bin',
    }),
  ).rejects.toThrowWithMessage(Error, 'the step is not a run step');
});

test('it rejects an output line in the multiline form', async () => {
  const ctx = await setupTest();

  expect(
    runActionsStep({
      step: { run: 'printf "notes<<EOF\\nheld\\nEOF\\n" >> "$GITHUB_OUTPUT"' },
      jobEnv: undefined,
      context: { github: {}, inputs: {}, steps: {} },
      cwd: ctx.workspace,
      directory: ctx.files,
      path: '/usr/bin:/bin',
    }),
  ).rejects.toThrowWithMessage(Error, 'unsupported output line: notes<<EOF');
});

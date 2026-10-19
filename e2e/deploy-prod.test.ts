import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { findJSONField } from '../scripts/find-json-field.ts';
import { buildMockWorkflowRunContext } from '../scripts/test-utils/build-mock-workflow-run-context.ts';
import { buildStubActionsScheduler } from '../scripts/test-utils/build-stub-actions-scheduler.ts';
import { isActionsConditionMet } from '../scripts/test-utils/is-actions-condition-met.ts';
import { runActionsStep } from '../scripts/test-utils/run-actions-step.ts';

// The Deploy prod workflow's runs through a stand-in for GitHub's scheduler: each test plays the
// runner, ending every job the scheduler starts with the result and outputs its steps give, which
// the suites of decide-prod-apply.sh and decide-prod-outcome.sh cover.
async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'deploy-prod-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const workflowText = await readFile(
    join(import.meta.dir, '..', '.github', 'workflows', 'deploy-prod.yml'),
    'utf8',
  );

  const workflow: unknown = Bun.YAML.parse(workflowText);
  const job = findJSONField(findJSONField(workflow, 'jobs'), 'apply');
  const steps = findJSONField(job, 'steps');

  if (!Array.isArray(steps)) {
    throw new TypeError('the apply job has no steps');
  }

  const stepList: readonly unknown[] = steps;

  return { directory, scheduler: buildStubActionsScheduler(workflowText), job, steps: stepList };
}

// the outcome step runs its real command with the env the workflow gives it, after a guard that
// held the plan of a push
test('it ends a held push s run green as held, from the workflow s own outcome step, and alerts the hold', async () => {
  const ctx = await setupTest();

  const github = buildMockWorkflowRunContext({ head_sha: 'a'.repeat(40) });
  const held = ctx.scheduler.startRun(github);
  const step = ctx.steps.find((each: unknown) => findJSONField(each, 'id') === 'outcome');

  const result = await runActionsStep({
    step,
    jobEnv: findJSONField(ctx.job, 'env'),
    context: {
      github,
      inputs: {},
      steps: {
        decide: { outputs: { apply: 'true', revision: 'a'.repeat(40) } },
        guard: { outputs: { verdict: 'hold' } },
      },
    },
    cwd: join(import.meta.dir, '..'),
    directory: ctx.directory,
    path: process.env['PATH'] ?? '/usr/bin:/bin',
  });

  ctx.scheduler.finishJob(held, 'apply', {
    status: result.status,
    steps: { outcome: result.outputs },
  });

  expect(result.summary).toBe(
    `The guard held the apply. To apply this plan, dispatch Deploy prod on main with revision ${'a'.repeat(40)}.\n`,
  );

  expect(ctx.scheduler.getRun(held)).toStrictEqual({
    status: 'in_progress',
    jobs: { apply: 'success', alert: 'in_progress' },
  });
});

test('it runs the control steps from the workflow s own checkout and the Pulumi program from the revision in program/', async () => {
  const ctx = await setupTest();

  const layout = ctx.steps.map((step: unknown) => ({
    name: findJSONField(step, 'name'),
    ref: findJSONField(findJSONField(step, 'with'), 'ref'),
    path: findJSONField(findJSONField(step, 'with'), 'path'),
    workingDirectory: findJSONField(step, 'working-directory'),
    program: findJSONField(findJSONField(step, 'env'), 'PROGRAM'),
    run: findJSONField(step, 'run'),
  }));

  expect(layout).toStrictEqual([
    {
      name: 'Checkout',
      ref: undefined,
      path: undefined,
      workingDirectory: undefined,
      program: undefined,
      run: undefined,
    },
    {
      name: 'Setup Bun',
      ref: undefined,
      path: undefined,
      workingDirectory: undefined,
      program: undefined,
      run: undefined,
    },
    {
      name: 'Decide whether the commit needs an apply',
      ref: undefined,
      path: undefined,
      workingDirectory: undefined,
      program: undefined,
      run: 'bun run --silent ci:decide-prod-apply',
    },
    {
      name: 'Check out the revision to apply',
      ref: `\${{ steps.decide.outputs.revision }}`,
      path: 'program',
      workingDirectory: undefined,
      program: undefined,
      run: undefined,
    },
    {
      name: 'Point .env at the deploy vault',
      ref: undefined,
      path: undefined,
      workingDirectory: undefined,
      program: undefined,
      run: 'bun run ci:write-deploy-env program/.env',
    },
    {
      name: 'Setup Go',
      ref: undefined,
      path: undefined,
      workingDirectory: undefined,
      program: undefined,
      run: undefined,
    },
    {
      name: 'Setup Pulumi',
      ref: undefined,
      path: undefined,
      workingDirectory: undefined,
      program: undefined,
      run: undefined,
    },
    {
      name: 'Setup 1Password CLI',
      ref: undefined,
      path: undefined,
      workingDirectory: undefined,
      program: undefined,
      run: undefined,
    },
    {
      name: 'Join the tailnet',
      ref: undefined,
      path: undefined,
      workingDirectory: undefined,
      program: undefined,
      run: undefined,
    },
    {
      name: 'Wait for the k3s API',
      ref: undefined,
      path: undefined,
      workingDirectory: undefined,
      program: undefined,
      run: 'bun run ci:wait-for-k3s-api',
    },
    {
      name: 'Install',
      ref: undefined,
      path: undefined,
      workingDirectory: 'program',
      program: undefined,
      run: 'bun install --frozen-lockfile',
    },
    {
      name: 'Check out the deployed revision',
      ref: undefined,
      path: undefined,
      workingDirectory: undefined,
      program: undefined,
      run: 'bun run ci:check-out-deployed-revision',
    },
    {
      name: 'Check drift from the deployed revision',
      ref: undefined,
      path: undefined,
      workingDirectory: undefined,
      program: undefined,
      run: 'bun run ci:retry-transient-pulumi -C "$DEPLOYED_DIR" bun run drift -- --suppress-outputs',
    },
    {
      name: 'Preview and guard',
      ref: undefined,
      path: undefined,
      workingDirectory: undefined,
      program: 'program',
      run: 'bun run --silent ci:preview-and-guard-prod',
    },
    {
      name: 'Decide the outcome',
      ref: undefined,
      path: undefined,
      workingDirectory: undefined,
      program: undefined,
      run: 'bun run --silent ci:decide-prod-outcome',
    },
    {
      name: 'Apply',
      ref: undefined,
      path: undefined,
      workingDirectory: 'program',
      program: undefined,
      run: 'bun run up -- --yes --refresh --skip-preview --suppress-outputs',
    },
    {
      name: 'Check drift after the apply',
      ref: undefined,
      path: undefined,
      workingDirectory: undefined,
      program: undefined,
      run: 'bun run ci:retry-transient-pulumi -C program bun run drift -- --suppress-outputs',
    },
    {
      name: 'Move deployed/prod',
      ref: undefined,
      path: undefined,
      workingDirectory: undefined,
      program: undefined,
      run: 'bun run ci:move-deployed-prod "$REVISION"',
    },
  ]);
});

test('it starts a waiting push s run as soon as a held run ends', async () => {
  const ctx = await setupTest();

  const held = ctx.scheduler.startRun(buildMockWorkflowRunContext({ head_sha: 'a'.repeat(40) }));
  const later = ctx.scheduler.startRun(buildMockWorkflowRunContext({ head_sha: 'b'.repeat(40) }));
  const laterBeforeTheHold = ctx.scheduler.getRun(later);

  ctx.scheduler.finishJob(held, 'apply', {
    status: 'success',
    steps: { outcome: { outcome: 'held' } },
  });

  expect(laterBeforeTheHold).toStrictEqual({
    status: 'in_progress',
    jobs: { apply: 'pending', alert: 'waiting' },
  });

  expect(ctx.scheduler.getRun(later)).toStrictEqual({
    status: 'in_progress',
    jobs: { apply: 'in_progress', alert: 'waiting' },
  });
});

test('it completes a later push s run that applies after a held run, with no alert', async () => {
  const ctx = await setupTest();

  const held = ctx.scheduler.startRun(buildMockWorkflowRunContext({ head_sha: 'a'.repeat(40) }));
  const later = ctx.scheduler.startRun(buildMockWorkflowRunContext({ head_sha: 'b'.repeat(40) }));

  ctx.scheduler.finishJob(held, 'apply', {
    status: 'success',
    steps: { outcome: { outcome: 'held' } },
  });

  ctx.scheduler.finishJob(later, 'apply', {
    status: 'success',
    steps: { outcome: { outcome: 'apply' } },
  });

  expect(ctx.scheduler.getRun(later)).toStrictEqual({
    status: 'completed',
    jobs: { apply: 'success', alert: 'skipped' },
  });
});

test('it alerts a failed apply', async () => {
  const ctx = await setupTest();

  const run = ctx.scheduler.startRun(buildMockWorkflowRunContext({ head_sha: 'a'.repeat(40) }));

  ctx.scheduler.finishJob(run, 'apply', {
    status: 'failure',
    steps: { outcome: { outcome: 'apply' } },
  });

  expect(ctx.scheduler.getRun(run)).toStrictEqual({
    status: 'in_progress',
    jobs: { apply: 'failure', alert: 'in_progress' },
  });
});

test('it completes a run with nothing to apply, with no alert', async () => {
  const ctx = await setupTest();

  const run = ctx.scheduler.startRun(buildMockWorkflowRunContext({ head_sha: 'a'.repeat(40) }));

  ctx.scheduler.finishJob(run, 'apply', { status: 'success' });

  expect(ctx.scheduler.getRun(run)).toStrictEqual({
    status: 'completed',
    jobs: { apply: 'success', alert: 'skipped' },
  });
});

test('it keeps every waiting run in the order it joined, and cancels none', async () => {
  const ctx = await setupTest();

  const running = ctx.scheduler.startRun(buildMockWorkflowRunContext({ head_sha: 'a'.repeat(40) }));
  const older = ctx.scheduler.startRun(buildMockWorkflowRunContext({ head_sha: 'b'.repeat(40) }));
  const newer = ctx.scheduler.startRun(buildMockWorkflowRunContext({ head_sha: 'c'.repeat(40) }));

  ctx.scheduler.finishJob(running, 'apply', {
    status: 'success',
    steps: { outcome: { outcome: 'apply' } },
  });

  expect(ctx.scheduler.getRun(older)).toStrictEqual({
    status: 'in_progress',
    jobs: { apply: 'in_progress', alert: 'waiting' },
  });

  expect(ctx.scheduler.getRun(newer)).toStrictEqual({
    status: 'in_progress',
    jobs: { apply: 'pending', alert: 'waiting' },
  });
});

test('it never queues the run of a failed CI run behind a running apply', async () => {
  const ctx = await setupTest();

  ctx.scheduler.startRun(buildMockWorkflowRunContext({ head_sha: 'a'.repeat(40) }));

  const failed = ctx.scheduler.startRun(
    buildMockWorkflowRunContext({ conclusion: 'failure', head_sha: 'b'.repeat(40) }),
  );

  expect(ctx.scheduler.getRun(failed)).toStrictEqual({
    status: 'completed',
    jobs: { apply: 'skipped', alert: 'skipped' },
  });
});

test('it starts nothing for the CI run of a pull request', async () => {
  const ctx = await setupTest();

  const run = ctx.scheduler.startRun(buildMockWorkflowRunContext({ event: 'pull_request' }));

  expect(ctx.scheduler.getRun(run)).toStrictEqual({
    status: 'completed',
    jobs: { apply: 'skipped', alert: 'skipped' },
  });
});

test.each([
  [
    'nothing to apply',
    { apply: 'false' },
    {},
    ['Checkout', 'Setup Bun', 'Decide whether the commit needs an apply'],
  ],
  [
    'a held plan',
    { apply: 'true' },
    { outcome: 'held' },
    [
      'Checkout',
      'Setup Bun',
      'Decide whether the commit needs an apply',
      'Check out the revision to apply',
      'Point .env at the deploy vault',
      'Setup Go',
      'Setup Pulumi',
      'Setup 1Password CLI',
      'Join the tailnet',
      'Wait for the k3s API',
      'Install',
      'Check out the deployed revision',
      'Check drift from the deployed revision',
      'Preview and guard',
      'Decide the outcome',
    ],
  ],
  [
    'a plan to apply',
    { apply: 'true' },
    { outcome: 'apply' },
    [
      'Checkout',
      'Setup Bun',
      'Decide whether the commit needs an apply',
      'Check out the revision to apply',
      'Point .env at the deploy vault',
      'Setup Go',
      'Setup Pulumi',
      'Setup 1Password CLI',
      'Join the tailnet',
      'Wait for the k3s API',
      'Install',
      'Check out the deployed revision',
      'Check drift from the deployed revision',
      'Preview and guard',
      'Decide the outcome',
      'Apply',
      'Check drift after the apply',
      'Move deployed/prod',
    ],
  ],
])('it runs only the steps %s needs', async (_label, decision, outcome, expected) => {
  const ctx = await setupTest();

  // a step with no `if` runs on success()
  const run = ctx.steps.filter((step: unknown) => {
    const condition = findJSONField(step, 'if') ?? 'success()';

    if (typeof condition !== 'string') {
      throw new TypeError(`a step's if is not an expression: ${JSON.stringify(condition)}`);
    }

    return isActionsConditionMet(condition, {
      github: { event_name: 'workflow_run' },
      needs: {},
      steps: {
        decide: { outcome: 'success', conclusion: 'success', outputs: decision },
        outcome: { outcome: 'success', conclusion: 'success', outputs: outcome },
      },
    });
  });

  expect(run.map((step: unknown) => findJSONField(step, 'name'))).toStrictEqual(expected);
});

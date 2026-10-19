import { expect, test } from 'bun:test';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { findJSONField } from '../scripts/find-json-field.ts';
import { buildMockWorkflowRunContext } from '../scripts/test-utils/build-mock-workflow-run-context.ts';
import { buildStubActionsScheduler } from '../scripts/test-utils/build-stub-actions-scheduler.ts';
import { isActionsConditionMet } from '../scripts/test-utils/is-actions-condition-met.ts';

// The Deploy prod workflow's runs through a stand-in for GitHub's scheduler: each test plays the
// runner, ending every job the scheduler starts with the result and outputs its steps give, which
// the suites of decide-prod-apply.sh and decide-prod-outcome.sh cover.
async function setupTest() {
  const workflowText = await readFile(
    join(import.meta.dir, '..', '.github', 'workflows', 'deploy-prod.yml'),
    'utf8',
  );

  return { scheduler: buildStubActionsScheduler(workflowText), workflowText };
}

test('it ends a held run with the apply job a success and alerts the hold', async () => {
  const ctx = await setupTest();

  const held = ctx.scheduler.startRun(buildMockWorkflowRunContext({ head_sha: 'a'.repeat(40) }));

  ctx.scheduler.finishJob(held, 'apply', { status: 'success', outputs: { outcome: 'held' } });

  expect(ctx.scheduler.getRun(held)).toStrictEqual({
    status: 'in_progress',
    jobs: { apply: 'success', alert: 'in_progress' },
  });
});

test('it starts a waiting push s run as soon as a held run ends', async () => {
  const ctx = await setupTest();

  const held = ctx.scheduler.startRun(buildMockWorkflowRunContext({ head_sha: 'a'.repeat(40) }));
  const later = ctx.scheduler.startRun(buildMockWorkflowRunContext({ head_sha: 'b'.repeat(40) }));
  const laterBeforeTheHold = ctx.scheduler.getRun(later);

  ctx.scheduler.finishJob(held, 'apply', { status: 'success', outputs: { outcome: 'held' } });

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

  ctx.scheduler.finishJob(held, 'apply', { status: 'success', outputs: { outcome: 'held' } });
  ctx.scheduler.finishJob(later, 'apply', { status: 'success', outputs: { outcome: 'apply' } });

  expect(ctx.scheduler.getRun(later)).toStrictEqual({
    status: 'completed',
    jobs: { apply: 'success', alert: 'skipped' },
  });
});

test('it alerts a failed apply', async () => {
  const ctx = await setupTest();

  const run = ctx.scheduler.startRun(buildMockWorkflowRunContext({ head_sha: 'a'.repeat(40) }));

  ctx.scheduler.finishJob(run, 'apply', { status: 'failure', outputs: { outcome: 'apply' } });

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

  ctx.scheduler.finishJob(running, 'apply', { status: 'success', outputs: { outcome: 'apply' } });

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

// each step's `if` against the outputs of the decision and the outcome steps
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

  const workflow: unknown = Bun.YAML.parse(ctx.workflowText);
  const steps = findJSONField(findJSONField(findJSONField(workflow, 'jobs'), 'apply'), 'steps');

  if (!Array.isArray(steps)) {
    throw new TypeError('the apply job has no steps');
  }

  // a step with no `if` runs on success()
  const run = steps.filter((step: unknown) => {
    const condition = findJSONField(step, 'if') ?? 'success()';

    if (typeof condition !== 'string') {
      throw new TypeError(`a step's if is not an expression: ${JSON.stringify(condition)}`);
    }

    return isActionsConditionMet(condition, {
      github: { event_name: 'workflow_run' },
      needs: {},
      steps: {
        decide: { outcome: 'success', outputs: decision },
        outcome: { outcome: 'success', outputs: outcome },
      },
    });
  });

  expect(run.map((step: unknown) => findJSONField(step, 'name'))).toStrictEqual(expected);
});

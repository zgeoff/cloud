import { expect, test } from 'bun:test';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { findJSONField } from '../scripts/find-json-field.ts';
import { buildMockWorkflowRunContext } from '../scripts/test-utils/build-mock-workflow-run-context.ts';
import { buildStubActionsScheduler } from '../scripts/test-utils/build-stub-actions-scheduler.ts';

// The Deploy prod workflow's runs through a stand-in for GitHub's scheduler: each test plays the
// runner, ending every job the scheduler starts with the result and outputs its steps give.
async function setupTest() {
  const workflowText = await readFile(
    join(import.meta.dir, '..', '.github', 'workflows', 'deploy-prod.yml'),
    'utf8',
  );

  return { scheduler: buildStubActionsScheduler(workflowText), workflowText };
}

test('it applies a successful revision that waited behind a running apply when a failed CI run follows', async () => {
  const ctx = await setupTest();

  const running = ctx.scheduler.startRun(buildMockWorkflowRunContext({ head_sha: 'a'.repeat(40) }));

  ctx.scheduler.finishJob(running, 'decide', {
    status: 'success',
    outputs: { apply: 'true', revision: 'a'.repeat(40) },
  });

  const waiting = ctx.scheduler.startRun(buildMockWorkflowRunContext({ head_sha: 'b'.repeat(40) }));

  ctx.scheduler.finishJob(waiting, 'decide', {
    status: 'success',
    outputs: { apply: 'true', revision: 'b'.repeat(40) },
  });

  const failed = ctx.scheduler.startRun(
    buildMockWorkflowRunContext({ conclusion: 'failure', head_sha: 'c'.repeat(40) }),
  );

  ctx.scheduler.finishJob(running, 'apply', { status: 'success', outputs: { verdict: 'apply' } });

  expect(ctx.scheduler.getRun(failed)).toStrictEqual({
    status: 'completed',
    jobs: { decide: 'skipped', apply: 'skipped', alert: 'skipped' },
  });

  expect(ctx.scheduler.getRun(waiting)).toStrictEqual({
    status: 'in_progress',
    jobs: { decide: 'success', apply: 'in_progress', alert: 'waiting' },
  });
});

test('it applies the newer revision, and alerts on the older, when two successful revisions wait behind a running apply', async () => {
  const ctx = await setupTest();

  const running = ctx.scheduler.startRun(buildMockWorkflowRunContext({ head_sha: 'a'.repeat(40) }));

  ctx.scheduler.finishJob(running, 'decide', {
    status: 'success',
    outputs: { apply: 'true', revision: 'a'.repeat(40) },
  });

  const older = ctx.scheduler.startRun(buildMockWorkflowRunContext({ head_sha: 'b'.repeat(40) }));

  ctx.scheduler.finishJob(older, 'decide', {
    status: 'success',
    outputs: { apply: 'true', revision: 'b'.repeat(40) },
  });

  const newer = ctx.scheduler.startRun(buildMockWorkflowRunContext({ head_sha: 'c'.repeat(40) }));

  ctx.scheduler.finishJob(newer, 'decide', {
    status: 'success',
    outputs: { apply: 'true', revision: 'c'.repeat(40) },
  });

  ctx.scheduler.finishJob(running, 'apply', { status: 'success', outputs: { verdict: 'apply' } });

  expect(ctx.scheduler.getRun(older)).toStrictEqual({
    status: 'in_progress',
    jobs: { decide: 'success', apply: 'cancelled', alert: 'in_progress' },
  });

  expect(ctx.scheduler.getRun(newer)).toStrictEqual({
    status: 'in_progress',
    jobs: { decide: 'success', apply: 'in_progress', alert: 'waiting' },
  });
});

test('it holds a newer decision until the older one ends, so the newer revision s apply waits behind the older one', async () => {
  const ctx = await setupTest();

  const older = ctx.scheduler.startRun(buildMockWorkflowRunContext({ head_sha: 'b'.repeat(40) }));
  const newer = ctx.scheduler.startRun(buildMockWorkflowRunContext({ head_sha: 'c'.repeat(40) }));
  const newerBeforeOlderDecided = ctx.scheduler.getRun(newer);

  ctx.scheduler.finishJob(older, 'decide', {
    status: 'success',
    outputs: { apply: 'true', revision: 'b'.repeat(40) },
  });

  ctx.scheduler.finishJob(newer, 'decide', {
    status: 'success',
    outputs: { apply: 'true', revision: 'c'.repeat(40) },
  });

  expect(newerBeforeOlderDecided).toStrictEqual({
    status: 'in_progress',
    jobs: { decide: 'pending', apply: 'waiting', alert: 'waiting' },
  });

  expect(ctx.scheduler.getRun(older)).toStrictEqual({
    status: 'in_progress',
    jobs: { decide: 'success', apply: 'in_progress', alert: 'waiting' },
  });

  expect(ctx.scheduler.getRun(newer)).toStrictEqual({
    status: 'in_progress',
    jobs: { decide: 'success', apply: 'pending', alert: 'waiting' },
  });
});

test('it never queues an apply for a commit with nothing to apply', async () => {
  const ctx = await setupTest();

  const running = ctx.scheduler.startRun(buildMockWorkflowRunContext({ head_sha: 'a'.repeat(40) }));

  ctx.scheduler.finishJob(running, 'decide', {
    status: 'success',
    outputs: { apply: 'true', revision: 'a'.repeat(40) },
  });

  const waiting = ctx.scheduler.startRun(buildMockWorkflowRunContext({ head_sha: 'b'.repeat(40) }));

  ctx.scheduler.finishJob(waiting, 'decide', {
    status: 'success',
    outputs: { apply: 'true', revision: 'b'.repeat(40) },
  });

  const docsOnly = ctx.scheduler.startRun(
    buildMockWorkflowRunContext({ head_sha: 'c'.repeat(40) }),
  );

  ctx.scheduler.finishJob(docsOnly, 'decide', {
    status: 'success',
    outputs: { apply: 'false', revision: 'c'.repeat(40) },
  });

  expect(ctx.scheduler.getRun(docsOnly)).toStrictEqual({
    status: 'completed',
    jobs: { decide: 'success', apply: 'skipped', alert: 'skipped' },
  });

  expect(ctx.scheduler.getRun(waiting)).toStrictEqual({
    status: 'in_progress',
    jobs: { decide: 'success', apply: 'pending', alert: 'waiting' },
  });
});

test('it starts nothing for the CI run of a pull request', async () => {
  const ctx = await setupTest();

  const run = ctx.scheduler.startRun(buildMockWorkflowRunContext({ event: 'pull_request' }));

  expect(ctx.scheduler.getRun(run)).toStrictEqual({
    status: 'completed',
    jobs: { decide: 'skipped', apply: 'skipped', alert: 'skipped' },
  });
});

test('it gates every apply step after the queued decision on that decision', async () => {
  const ctx = await setupTest();

  const workflow: unknown = Bun.YAML.parse(ctx.workflowText);
  const found = findJSONField(findJSONField(findJSONField(workflow, 'jobs'), 'apply'), 'steps');

  if (!Array.isArray(found)) {
    throw new TypeError('the apply job has no steps');
  }

  const steps: readonly unknown[] = found;
  const queued = steps.findIndex((step: unknown) => findJSONField(step, 'id') === 'queued');

  expect(queued).toBe(2);

  expect(steps.slice(queued + 1).map((step: unknown) => findJSONField(step, 'if'))).toSatisfyAll(
    (condition: unknown) =>
      typeof condition === 'string' && condition.startsWith("steps.queued.outputs.apply == 'true'"),
  );
});

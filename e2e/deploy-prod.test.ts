import { expect, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { $ } from 'bun';
import { findJSONField } from '../scripts/find-json-field.ts';
import { buildActionsJobResult } from '../scripts/test-utils/build-actions-job-result.ts';
import { buildMockWorkflowRunContext } from '../scripts/test-utils/build-mock-workflow-run-context.ts';
import { buildStubActionsScheduler } from '../scripts/test-utils/build-stub-actions-scheduler.ts';
import { isActionsConditionMet } from '../scripts/test-utils/is-actions-condition-met.ts';
import { renderActionsTemplate } from '../scripts/test-utils/render-actions-template.ts';
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
    jobs: { apply: 'success', check: 'skipped', alert: 'in_progress' },
  });
});

// the refresh step runs its real command with real Bun, the real refresh-prod.sh and the real
// retry, from a workspace that links this checkout's package.json and scripts/; only op, pulumi and
// the retry's pause are stand-ins
test('it refreshes the prod stack from the workflow s own refresh step, again after a cloudflare 502 to a get', async () => {
  const ctx = await setupTest();

  const repo = join(import.meta.dir, '..');
  const workspace = join(ctx.directory, 'workspace');
  const bin = join(ctx.directory, 'bin');
  const clock = join(ctx.directory, 'clock');
  const pulumiAnswers = join(ctx.directory, 'pulumi-answers');
  const pulumiCalls = join(ctx.directory, 'pulumi-calls');
  const opCalls = join(ctx.directory, 'op-calls');

  await mkdir(join(workspace, 'program', 'infra'), { recursive: true });
  await mkdir(bin);
  await mkdir(clock);
  await mkdir(pulumiAnswers);
  await symlink(join(repo, 'package.json'), join(workspace, 'package.json'));
  await symlink(join(repo, 'scripts'), join(workspace, 'scripts'));

  // the revision to apply builds its provider with Go, which this test leaves out
  await writeFile(
    join(workspace, 'program', 'package.json'),
    JSON.stringify({ scripts: { 'provider:build': 'echo built the provider' } }),
  );

  await writeFile(
    join(workspace, 'program', '.env'),
    'PULUMI_CONFIG_PASSPHRASE=op://example/passphrase/password\n',
  );

  await writeFile(
    join(pulumiAnswers, '1.err'),
    '    error: failed to make http request: GET "https://api.cloudflare.com/client/v4/accounts/0a1b2c3d/access/apps/5f6e7d8c": 502 Bad Gateway\n',
  );

  await writeFile(join(pulumiAnswers, '1.status'), '255\n');
  await writeFile(join(pulumiAnswers, '2.out'), 'Resources:\n    80 unchanged\n');
  await writeFile(pulumiCalls, '');
  await writeFile(opCalls, '');
  await $`bash -c ${'source "$1"; source "$2"; source "$3"; create_stub_clock "$4"; create_stub_op_run "$5" "$6"; create_stub_scripted_command "$5" pulumi "$7" "$8"'} create-stubs ${join(repo, 'test-support', 'shell', 'create-stub-clock.sh')} ${join(repo, 'test-support', 'shell', 'create-stub-op-run.sh')} ${join(repo, 'test-support', 'shell', 'create-stub-scripted-command.sh')} ${clock} ${bin} ${opCalls} ${pulumiCalls} ${pulumiAnswers}`;

  const step = ctx.steps.find(
    (each: unknown) => findJSONField(each, 'name') === 'Refresh before the apply',
  );

  const result = await runActionsStep({
    step,
    jobEnv: findJSONField(ctx.job, 'env'),
    context: {
      github: buildMockWorkflowRunContext({ head_sha: 'a'.repeat(40) }),
      inputs: {},
      steps: {},
      secrets: { OP_SERVICE_ACCOUNT_TOKEN: 'ops_example' },
    },
    cwd: workspace,
    directory: ctx.directory,
    path: `${clock}:${bin}:${dirname(process.execPath)}:/usr/bin:/bin`,
  });

  const pulumiLog = await readFile(pulumiCalls, 'utf8');
  const opLog = await readFile(opCalls, 'utf8');
  const pauses = await readFile(join(clock, 'pauses'), 'utf8');

  expect(result.status).toBe('success');

  expect(result.stdout).toBe(
    'built the provider\n    error: failed to make http request: GET "https://api.cloudflare.com/client/v4/accounts/0a1b2c3d/access/apps/5f6e7d8c": 502 Bad Gateway\nResources:\n    80 unchanged\n',
  );

  expect(pulumiLog).toBe(
    `${JSON.stringify({ cwd: join(workspace, 'program', 'infra'), argv: ['pulumi', 'refresh', '--stack', 'prod', '--yes', '--skip-preview', '--suppress-outputs'] })}\n`.repeat(
      2,
    ),
  );

  expect(opLog).toBe(
    `${JSON.stringify({ cwd: join(workspace, 'program', 'infra'), argv: ['op', 'run', '--env-file=../.env', '--', 'pulumi', 'refresh', '--stack', 'prod', '--yes', '--skip-preview', '--suppress-outputs'] })}\n`.repeat(
      2,
    ),
  );

  expect(pauses).toBe('60\n');
});

// main's tip, whose workflow runs, is a later merge than the commit whose CI run started it.
// actions/checkout checks out the event's github.sha when a step names no ref (its README's ref
// input).
test('it checks out the workflow s revision for the control steps and the decided revision into program/', async () => {
  const ctx = await setupTest();

  const context = {
    github: { ...buildMockWorkflowRunContext({ head_sha: 'a'.repeat(40) }), sha: 'b'.repeat(40) },
    inputs: {},
    steps: { decide: { outputs: { apply: 'true', revision: 'a'.repeat(40) } } },
  };

  const checkouts = ctx.steps
    .filter((step: unknown) => String(findJSONField(step, 'uses')).startsWith('actions/checkout@'))
    .map((step: unknown) => ({
      path: findJSONField(findJSONField(step, 'with'), 'path') ?? '.',
      ref: renderActionsTemplate(
        findJSONField(findJSONField(step, 'with'), 'ref') ?? `\${{ github.sha }}`,
        context,
      ),
    }));

  expect(checkouts).toStrictEqual([
    { path: '.', ref: 'b'.repeat(40) },
    { path: 'program', ref: 'a'.repeat(40) },
  ]);
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
      name: 'Take the prod lock',
      ref: undefined,
      path: undefined,
      workingDirectory: undefined,
      program: undefined,
      run: 'bun run ci:hold-deploy-prod-lock take',
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
      name: 'Refresh before the apply',
      ref: undefined,
      path: undefined,
      workingDirectory: undefined,
      program: 'program',
      run: 'bun run --silent ci:refresh-prod',
    },
    {
      name: 'Apply',
      ref: undefined,
      path: undefined,
      workingDirectory: 'program',
      program: undefined,
      run: 'bun run up -- --yes --skip-preview --suppress-outputs',
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
    {
      name: "Check nixie's API",
      ref: undefined,
      path: undefined,
      workingDirectory: 'program',
      program: undefined,
      run: 'bun run ci:check-nixie-api',
    },
    {
      name: 'Release the prod lock',
      ref: undefined,
      path: undefined,
      workingDirectory: undefined,
      program: undefined,
      run: 'bun run ci:hold-deploy-prod-lock release',
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
    jobs: { apply: 'pending', check: 'waiting', alert: 'waiting' },
  });

  expect(ctx.scheduler.getRun(later)).toStrictEqual({
    status: 'in_progress',
    jobs: { apply: 'in_progress', check: 'waiting', alert: 'waiting' },
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
    outcomes: { nixie_check: 'success' },
  });

  ctx.scheduler.finishJob(later, 'check', { status: 'success' });

  expect(ctx.scheduler.getRun(later)).toStrictEqual({
    status: 'completed',
    jobs: { apply: 'success', check: 'success', alert: 'skipped' },
  });
});

test('it starts the check job once an apply job that applied ends', async () => {
  const ctx = await setupTest();

  const run = ctx.scheduler.startRun(buildMockWorkflowRunContext({ head_sha: 'a'.repeat(40) }));

  ctx.scheduler.finishJob(run, 'apply', {
    status: 'success',
    steps: { outcome: { outcome: 'apply' } },
    outcomes: { nixie_check: 'failure' },
  });

  expect(ctx.scheduler.getRun(run)).toStrictEqual({
    status: 'in_progress',
    jobs: { apply: 'success', check: 'in_progress', alert: 'waiting' },
  });
});

// the apply job's result comes from its own steps, so a failed check step fails the apply job
// unless the workflow lets that step fail
test('it keeps the apply green and alerts when the check of nixie s API fails', async () => {
  const ctx = await setupTest();

  const run = ctx.scheduler.startRun(buildMockWorkflowRunContext({ head_sha: 'a'.repeat(40) }));

  const outcomes = {
    decide: 'success',
    guard: 'success',
    outcome: 'success',
    nixie_check: 'failure',
  };

  ctx.scheduler.finishJob(run, 'apply', {
    status: buildActionsJobResult(ctx.steps, outcomes),
    steps: { outcome: { outcome: 'apply' } },
    outcomes,
  });

  ctx.scheduler.finishJob(run, 'check', { status: 'failure' });

  expect(ctx.scheduler.getRun(run)).toStrictEqual({
    status: 'in_progress',
    jobs: { apply: 'success', check: 'failure', alert: 'in_progress' },
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
    jobs: { apply: 'failure', check: 'skipped', alert: 'in_progress' },
  });
});

test('it completes a run with nothing to apply, with no alert', async () => {
  const ctx = await setupTest();

  const run = ctx.scheduler.startRun(buildMockWorkflowRunContext({ head_sha: 'a'.repeat(40) }));

  ctx.scheduler.finishJob(run, 'apply', { status: 'success' });

  expect(ctx.scheduler.getRun(run)).toStrictEqual({
    status: 'completed',
    jobs: { apply: 'success', check: 'skipped', alert: 'skipped' },
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
    jobs: { apply: 'in_progress', check: 'waiting', alert: 'waiting' },
  });

  expect(ctx.scheduler.getRun(newer)).toStrictEqual({
    status: 'in_progress',
    jobs: { apply: 'pending', check: 'waiting', alert: 'waiting' },
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
    jobs: { apply: 'skipped', check: 'skipped', alert: 'skipped' },
  });
});

test('it releases the prod lock after a step fails', async () => {
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
        decide: { outcome: 'success', conclusion: 'success', outputs: { apply: 'true' } },
        guard: { outcome: 'failure', conclusion: 'failure', outputs: {} },
      },
    });
  });

  expect(run.map((step: unknown) => findJSONField(step, 'name'))).toStrictEqual([
    'Release the prod lock',
  ]);
});

test('it starts nothing for the CI run of a pull request', async () => {
  const ctx = await setupTest();

  const run = ctx.scheduler.startRun(buildMockWorkflowRunContext({ event: 'pull_request' }));

  expect(ctx.scheduler.getRun(run)).toStrictEqual({
    status: 'completed',
    jobs: { apply: 'skipped', check: 'skipped', alert: 'skipped' },
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
      'Take the prod lock',
      'Check drift from the deployed revision',
      'Preview and guard',
      'Decide the outcome',
      'Release the prod lock',
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
      'Take the prod lock',
      'Check drift from the deployed revision',
      'Preview and guard',
      'Decide the outcome',
      'Refresh before the apply',
      'Apply',
      'Check drift after the apply',
      'Move deployed/prod',
      "Check nixie's API",
      'Release the prod lock',
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

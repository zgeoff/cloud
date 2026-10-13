import { expect, test } from 'bun:test';
import { buildStubActionsScheduler } from './build-stub-actions-scheduler.ts';

test('it starts a job once the job it needs succeeds', () => {
  const scheduler = buildStubActionsScheduler(`
jobs:
  build:
    runs-on: ubuntu-latest
  ship:
    needs: build
    runs-on: ubuntu-latest
`);

  const run = scheduler.startRun({ event_name: 'push', repository: 'zgeoff/cloud', event: {} });

  scheduler.finishJob(run, 'build', { status: 'success' });

  expect(scheduler.getRun(run)).toStrictEqual({
    status: 'in_progress',
    jobs: { build: 'success', ship: 'in_progress' },
  });
});

test('it completes a run once every job ends', () => {
  const scheduler = buildStubActionsScheduler(`
jobs:
  build:
    runs-on: ubuntu-latest
`);

  const run = scheduler.startRun({ event_name: 'push', repository: 'zgeoff/cloud', event: {} });

  scheduler.finishJob(run, 'build', { status: 'success' });

  expect(scheduler.getRun(run)).toStrictEqual({ status: 'completed', jobs: { build: 'success' } });
});

test('it skips a job whose if does not hold, and the job that needs it', () => {
  const scheduler = buildStubActionsScheduler(`
jobs:
  build:
    if: github.event_name == 'workflow_dispatch'
    runs-on: ubuntu-latest
  ship:
    needs: build
    runs-on: ubuntu-latest
`);

  const run = scheduler.startRun({ event_name: 'push', repository: 'zgeoff/cloud', event: {} });

  expect(scheduler.getRun(run)).toStrictEqual({
    status: 'completed',
    jobs: { build: 'skipped', ship: 'skipped' },
  });
});

test('it skips a job after a failed need unless its if calls a status function', () => {
  const scheduler = buildStubActionsScheduler(`
jobs:
  build:
    runs-on: ubuntu-latest
  ship:
    needs: build
    runs-on: ubuntu-latest
  alert:
    needs: build
    if: always() && needs.build.result == 'failure'
    runs-on: ubuntu-latest
`);

  const run = scheduler.startRun({ event_name: 'push', repository: 'zgeoff/cloud', event: {} });

  scheduler.finishJob(run, 'build', { status: 'failure' });

  expect(scheduler.getRun(run)).toStrictEqual({
    status: 'in_progress',
    jobs: { build: 'failure', ship: 'skipped', alert: 'in_progress' },
  });
});

test('it gives a job the outputs of the jobs it needs', () => {
  const scheduler = buildStubActionsScheduler(`
jobs:
  decide:
    runs-on: ubuntu-latest
  apply:
    needs: decide
    if: needs.decide.outputs.apply == 'true'
    runs-on: ubuntu-latest
  skip:
    needs: decide
    if: needs.decide.outputs.apply == 'false'
    runs-on: ubuntu-latest
`);

  const run = scheduler.startRun({ event_name: 'push', repository: 'zgeoff/cloud', event: {} });

  scheduler.finishJob(run, 'decide', { status: 'success', outputs: { apply: 'true' } });

  expect(scheduler.getRun(run)).toStrictEqual({
    status: 'in_progress',
    jobs: { decide: 'success', apply: 'in_progress', skip: 'skipped' },
  });
});

test('it gives a job the event that started the run', () => {
  const scheduler = buildStubActionsScheduler(`
jobs:
  build:
    if: github.event.workflow_run.conclusion == 'success' && github.repository == 'zgeoff/cloud'
    runs-on: ubuntu-latest
`);

  const run = scheduler.startRun({
    event_name: 'workflow_run',
    repository: 'zgeoff/cloud',
    event: { workflow_run: { conclusion: 'success' } },
  });

  expect(scheduler.getRun(run)).toStrictEqual({
    status: 'in_progress',
    jobs: { build: 'in_progress' },
  });
});

test('it holds a second run of a workflow-level group pending until the first completes', () => {
  const scheduler = buildStubActionsScheduler(`
concurrency:
  group: deploy
  cancel-in-progress: false
jobs:
  ship:
    runs-on: ubuntu-latest
`);

  const first = scheduler.startRun({ event_name: 'push', repository: 'zgeoff/cloud', event: {} });
  const second = scheduler.startRun({ event_name: 'push', repository: 'zgeoff/cloud', event: {} });
  const pending = scheduler.getRun(second);

  scheduler.finishJob(first, 'ship', { status: 'success' });

  expect(pending).toStrictEqual({ status: 'pending', jobs: { ship: 'waiting' } });

  expect(scheduler.getRun(second)).toStrictEqual({
    status: 'in_progress',
    jobs: { ship: 'in_progress' },
  });
});

test('it cancels the pending run when a newer run joins a workflow-level group', () => {
  const scheduler = buildStubActionsScheduler(`
concurrency:
  group: deploy
jobs:
  ship:
    runs-on: ubuntu-latest
`);

  scheduler.startRun({ event_name: 'push', repository: 'zgeoff/cloud', event: {} });

  const second = scheduler.startRun({ event_name: 'push', repository: 'zgeoff/cloud', event: {} });

  scheduler.startRun({ event_name: 'push', repository: 'zgeoff/cloud', event: {} });

  expect(scheduler.getRun(second)).toStrictEqual({
    status: 'cancelled',
    jobs: { ship: 'cancelled' },
  });
});

test('it compares group names case-insensitively', () => {
  const scheduler = buildStubActionsScheduler(`
jobs:
  ship:
    concurrency: Deploy
    runs-on: ubuntu-latest
  publish:
    concurrency: deploy
    runs-on: ubuntu-latest
`);

  const run = scheduler.startRun({ event_name: 'push', repository: 'zgeoff/cloud', event: {} });

  expect(scheduler.getRun(run)).toStrictEqual({
    status: 'in_progress',
    jobs: { ship: 'in_progress', publish: 'pending' },
  });
});

test('it cancels the pending job when a newer job joins a job-level group', () => {
  const scheduler = buildStubActionsScheduler(`
jobs:
  ship:
    concurrency:
      group: deploy
    runs-on: ubuntu-latest
`);

  const first = scheduler.startRun({ event_name: 'push', repository: 'zgeoff/cloud', event: {} });
  const second = scheduler.startRun({ event_name: 'push', repository: 'zgeoff/cloud', event: {} });
  const third = scheduler.startRun({ event_name: 'push', repository: 'zgeoff/cloud', event: {} });

  scheduler.finishJob(first, 'ship', { status: 'success' });

  expect(scheduler.getRun(second)).toStrictEqual({
    status: 'completed',
    jobs: { ship: 'cancelled' },
  });

  expect(scheduler.getRun(third)).toStrictEqual({
    status: 'in_progress',
    jobs: { ship: 'in_progress' },
  });
});

test('it never adds a job its if skips to the job s group', () => {
  const scheduler = buildStubActionsScheduler(`
jobs:
  ship:
    if: github.event_name == 'push'
    concurrency:
      group: deploy
    runs-on: ubuntu-latest
`);

  scheduler.startRun({ event_name: 'push', repository: 'zgeoff/cloud', event: {} });

  const second = scheduler.startRun({ event_name: 'push', repository: 'zgeoff/cloud', event: {} });

  scheduler.startRun({ event_name: 'schedule', repository: 'zgeoff/cloud', event: {} });

  expect(scheduler.getRun(second)).toStrictEqual({
    status: 'in_progress',
    jobs: { ship: 'pending' },
  });
});

test('it keeps every pending job of a queue: max group, and starts them in the order they joined', () => {
  const scheduler = buildStubActionsScheduler(`
jobs:
  ship:
    concurrency:
      group: deploy
      queue: max
    runs-on: ubuntu-latest
`);

  const first = scheduler.startRun({ event_name: 'push', repository: 'zgeoff/cloud', event: {} });
  const second = scheduler.startRun({ event_name: 'push', repository: 'zgeoff/cloud', event: {} });
  const third = scheduler.startRun({ event_name: 'push', repository: 'zgeoff/cloud', event: {} });

  scheduler.finishJob(first, 'ship', { status: 'success' });

  expect(scheduler.getRun(second)).toStrictEqual({
    status: 'in_progress',
    jobs: { ship: 'in_progress' },
  });

  expect(scheduler.getRun(third)).toStrictEqual({
    status: 'in_progress',
    jobs: { ship: 'pending' },
  });
});

test('it keeps every pending run of a workflow-level queue: max group', () => {
  const scheduler = buildStubActionsScheduler(`
concurrency:
  group: deploy
  queue: max
jobs:
  ship:
    runs-on: ubuntu-latest
`);

  scheduler.startRun({ event_name: 'push', repository: 'zgeoff/cloud', event: {} });

  const second = scheduler.startRun({ event_name: 'push', repository: 'zgeoff/cloud', event: {} });

  scheduler.startRun({ event_name: 'push', repository: 'zgeoff/cloud', event: {} });

  expect(scheduler.getRun(second)).toStrictEqual({ status: 'pending', jobs: { ship: 'waiting' } });
});

test('it cancels a job that joins a queue: max group with 100 jobs already pending', () => {
  const scheduler = buildStubActionsScheduler(`
jobs:
  ship:
    concurrency:
      group: deploy
      queue: max
    runs-on: ubuntu-latest
`);

  Array.from({ length: 101 }, () =>
    scheduler.startRun({ event_name: 'push', repository: 'zgeoff/cloud', event: {} }),
  );

  const overflow = scheduler.startRun({
    event_name: 'push',
    repository: 'zgeoff/cloud',
    event: {},
  });

  expect(scheduler.getRun(overflow)).toStrictEqual({
    status: 'completed',
    jobs: { ship: 'cancelled' },
  });

  expect(scheduler.getRun(101)).toStrictEqual({
    status: 'in_progress',
    jobs: { ship: 'pending' },
  });
});

test('it rejects a workflow whose concurrency it does not model', () => {
  expect(() =>
    buildStubActionsScheduler(`
concurrency:
  group: deploy
  cancel-in-progress: true
jobs:
  ship:
    runs-on: ubuntu-latest
`),
  ).toThrowWithMessage(Error, 'unsupported concurrency: cancel-in-progress');
});

test('it refuses to finish a job that is not in progress', () => {
  const scheduler = buildStubActionsScheduler(`
jobs:
  build:
    runs-on: ubuntu-latest
  ship:
    needs: build
    runs-on: ubuntu-latest
`);

  const run = scheduler.startRun({ event_name: 'push', repository: 'zgeoff/cloud', event: {} });

  expect(() => {
    scheduler.finishJob(run, 'ship', { status: 'success' });
  }).toThrowWithMessage(Error, 'run 1 job ship is waiting, not in_progress');
});

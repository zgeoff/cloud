import { buildStubConcurrencyGroup } from './build-stub-concurrency-group.ts';
import type { StubConcurrencyGroup } from './build-stub-concurrency-group.ts';
import { isActionsConditionMet } from './is-actions-condition-met.ts';
import { parseActionsWorkflow } from './parse-actions-workflow.ts';
import type { ActionsConcurrency, ActionsJob, ActionsWorkflow } from './parse-actions-workflow.ts';

// Stands in for GitHub Actions' scheduler for one workflow, per GitHub's docs on 2026-10-13
// ("Workflow syntax", "Evaluate expressions", "Control the concurrency of workflows and jobs"). The
// test plays the runner and ends each started job; no step runs.
export interface StubGitHubContext {
  readonly event_name: string;
  readonly repository: string;
  readonly event: Readonly<Record<string, unknown>>;
}

type DoneStatus = 'success' | 'failure' | 'skipped' | 'cancelled';

type StubJobStatus = 'waiting' | 'pending' | 'in_progress' | DoneStatus;

interface StubRun {
  readonly status: 'pending' | 'in_progress' | 'completed' | 'cancelled';
  readonly jobs: Readonly<Record<string, StubJobStatus>>;
}

interface StubJobResult {
  readonly status: 'success' | 'failure';
  readonly outputs?: Readonly<Record<string, string>>;
}

export interface StubActionsScheduler {
  // starts a run of the workflow for the event, and returns its id
  readonly startRun: (github: StubGitHubContext) => number;

  // ends a job the scheduler started
  readonly finishJob: (runID: number, job: string, result: StubJobResult) => void;

  readonly getRun: (runID: number) => StubRun;
}

export function buildStubActionsScheduler(workflowText: string): StubActionsScheduler {
  const workflow = parseActionsWorkflow(workflowText);
  const state: SchedulerState = { workflow, runs: [], groups: new Map() };

  return {
    startRun: (github) => createRun(state, github),
    finishJob: (runID, job, result) => {
      updateFinishedJob(state, { runID, job }, result);
    },
    getRun: (runID) => {
      const run = getRunState(state, runID);

      return {
        status: run.status,
        jobs: Object.fromEntries([...run.jobs].map(([name, job]) => [name, job.status])),
      };
    },
  };
}

interface JobState {
  status: StubJobStatus;
  outputs: Readonly<Record<string, string>>;
}

interface RunState {
  status: StubRun['status'];
  readonly github: StubGitHubContext;
  readonly jobs: Map<string, JobState>;
}

// a run for a workflow-level group, a job of a run for a job-level one
interface Holder {
  readonly runID: number;
  readonly job?: string;
}

// each group takes the queue mode of the concurrency that first names it
interface SchedulerState {
  readonly workflow: ActionsWorkflow;
  readonly runs: RunState[];
  readonly groups: Map<string, StubConcurrencyGroup<Holder>>;
}

function createRun(state: SchedulerState, github: StubGitHubContext): number {
  const runID = state.runs.length + 1;

  const statuses = state.workflow.jobs.map((job): [string, JobState] => [
    job.name,
    { status: 'waiting', outputs: {} },
  ]);

  const run: RunState = { status: 'in_progress', github, jobs: new Map(statuses) };

  state.runs.push(run);

  if (state.workflow.concurrency !== undefined) {
    run.status = 'pending';

    registerHolder(state, state.workflow.concurrency, { runID });
  }

  updateRuns(state);

  return runID;
}

function updateFinishedJob(state: SchedulerState, holder: Required<Holder>, result: StubJobResult) {
  const job = getRunState(state, holder.runID).jobs.get(holder.job);

  if (job?.status !== 'in_progress') {
    throw new Error(
      `run ${holder.runID} job ${holder.job} is ${job?.status ?? 'missing'}, not in_progress`,
    );
  }

  job.status = result.status;
  job.outputs = result.outputs ?? {};

  const concurrency = state.workflow.jobs.find((each) => each.name === holder.job)?.concurrency;

  if (concurrency !== undefined) {
    removeRunningHolder(state, concurrency);
  }

  updateRuns(state);
}

function getRunState(state: SchedulerState, runID: number): RunState {
  const run = state.runs[runID - 1];

  if (run === undefined) {
    throw new Error(`no run ${runID}`);
  }

  return run;
}

// A job its `if` skips, which the docs leave unsettled, never registers, so it neither waits nor
// cancels.
function registerHolder(state: SchedulerState, concurrency: ActionsConcurrency, holder: Holder) {
  const group =
    state.groups.get(concurrency.group) ?? buildStubConcurrencyGroup<Holder>(concurrency.queue);

  state.groups.set(concurrency.group, group);

  const joined = group.join(holder);

  if (joined.started) {
    startHolder(state, holder);
  }

  joined.cancelled.forEach((each) => {
    updateToCancelled(state, each);
  });
}

function startHolder(state: SchedulerState, holder: Holder): void {
  const run = getRunState(state, holder.runID);

  if (holder.job === undefined) {
    run.status = 'in_progress';

    return;
  }

  setJobStatus(run, holder.job, 'in_progress');
}

function updateToCancelled(state: SchedulerState, holder: Holder): void {
  const run = getRunState(state, holder.runID);

  if (holder.job !== undefined) {
    setJobStatus(run, holder.job, 'cancelled');

    return;
  }

  run.status = 'cancelled';

  run.jobs.forEach((job) => {
    job.status = 'cancelled';
  });
}

function setJobStatus(run: RunState, job: string, status: StubJobStatus): void {
  const jobState = run.jobs.get(job);

  if (jobState === undefined) {
    throw new Error(`no job ${job}`);
  }

  jobState.status = status;
}

function removeRunningHolder(state: SchedulerState, concurrency: ActionsConcurrency): void {
  const group = state.groups.get(concurrency.group);

  if (group === undefined) {
    throw new Error(`no group ${concurrency.group}`);
  }

  const next = group.finish();

  if (next !== undefined) {
    startHolder(state, next);
  }
}

const doneStatuses = new Set<StubJobStatus>(['success', 'failure', 'skipped', 'cancelled']);

// starts each waiting job whose needs have ended, and ends each run whose jobs all have, until
// nothing changes
function updateRuns(state: SchedulerState): void {
  let changed = true;

  while (changed) {
    changed = state.runs.some((run, index) => updateRun(state, run, index + 1));
  }
}

function updateRun(state: SchedulerState, run: RunState, runID: number): boolean {
  if (run.status !== 'in_progress') {
    return false;
  }

  const ready = state.workflow.jobs.find((job) => isReady(run, job));

  if (ready === undefined) {
    return updateCompletedRun(state, run);
  }

  startJob(state, { runID, job: ready.name }, ready);

  return true;
}

function isReady(run: RunState, job: ActionsJob): boolean {
  return (
    run.jobs.get(job.name)?.status === 'waiting' &&
    job.needs.every((need) => doneStatuses.has(run.jobs.get(need)?.status ?? 'waiting'))
  );
}

function updateCompletedRun(state: SchedulerState, run: RunState): boolean {
  if (![...run.jobs.values()].every((job) => doneStatuses.has(job.status))) {
    return false;
  }

  run.status = 'completed';

  if (state.workflow.concurrency !== undefined) {
    removeRunningHolder(state, state.workflow.concurrency);
  }

  return true;
}

function startJob(state: SchedulerState, holder: Required<Holder>, job: ActionsJob): void {
  const run = getRunState(state, holder.runID);

  const needs = Object.fromEntries(
    job.needs.map((need) => {
      const needState = run.jobs.get(need);

      return [need, { result: needState?.status ?? 'waiting', outputs: needState?.outputs ?? {} }];
    }),
  );

  if (!isActionsConditionMet(job.condition ?? 'success()', { github: run.github, needs })) {
    setJobStatus(run, job.name, 'skipped');

    return;
  }

  if (job.concurrency === undefined) {
    setJobStatus(run, job.name, 'in_progress');

    return;
  }

  setJobStatus(run, job.name, 'pending');
  registerHolder(state, job.concurrency, holder);
}

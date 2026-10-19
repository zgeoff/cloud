import { findJSONField } from '../find-json-field.ts';

export interface WorkflowEvent {
  readonly name: string;
  readonly payload: unknown;
  readonly repository: string;
}

export function findEventBranch(event: WorkflowEvent): string | undefined {
  if (event.name === 'workflow_run') {
    return findWorkflowRunBranch(event.payload, event.repository);
  }

  // a bump run that pushes and then fails leaves the pull request without the label, and its
  // checks can all finish before the next run puts it back, so no check finishes after the repair
  if (event.name === 'pull_request_target') {
    return findLabeledBranch(event.payload, event.repository);
  }

  return undefined;
}

function findWorkflowRunBranch(payload: unknown, repository: string) {
  const run = findJSONField(payload, 'workflow_run');
  const branch = findJSONField(run, 'head_branch');

  return findJSONField(run, 'event') === 'pull_request' &&
    findJSONField(findJSONField(run, 'head_repository'), 'full_name') === repository &&
    typeof branch === 'string'
    ? branch
    : undefined;
}

function findLabeledBranch(payload: unknown, repository: string) {
  const head = findJSONField(findJSONField(payload, 'pull_request'), 'head');
  const branch = findJSONField(head, 'ref');

  return findJSONField(payload, 'action') === 'labeled' &&
    findJSONField(findJSONField(payload, 'label'), 'name') === 'auto-merge' &&
    findJSONField(findJSONField(head, 'repo'), 'full_name') === repository &&
    typeof branch === 'string'
    ? branch
    : undefined;
}

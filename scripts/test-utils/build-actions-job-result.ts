import { findJSONField } from '../find-json-field.ts';

// A job's result from its steps' outcomes, per GitHub's "Workflow syntax"
// (jobs.<job_id>.steps[*].continue-on-error) and "Contexts" (steps.<step_id>.conclusion): a failed
// step fails the job unless its continue-on-error is true. A step missing from outcomes passed.
export function buildActionsJobResult(
  steps: readonly unknown[],
  outcomes: Readonly<Record<string, string>>,
): 'success' | 'failure' {
  const failed = steps.filter((step) => {
    const id = findJSONField(step, 'id');

    return typeof id === 'string' && outcomes[id] === 'failure';
  });

  return failed.every((step) => findJSONField(step, 'continue-on-error') === true)
    ? 'success'
    : 'failure';
}

import { match } from 'ts-pattern';

// Stands in for GitHub Actions' trigger filters, per GitHub's "Workflow syntax" and "Filter pattern
// cheat sheet" docs on 2026-10-20. It throws on a filter or a pattern it does not model, such as
// paths-ignore or a negated pattern, so a test never passes on a rule the stand-in ignores.
export type ActionsTriggerEvent =
  | {
      readonly name: 'pull_request';
      readonly baseBranch: string;
      readonly files: readonly string[];
    }
  | { readonly name: 'schedule' }
  | { readonly name: 'workflow_dispatch' }
  | {
      readonly name: 'workflow_run';
      readonly workflow: string;
      readonly type: 'requested' | 'in_progress' | 'completed';
      readonly headBranch: string;
    };

export function isWorkflowTriggered(workflowText: string, event: ActionsTriggerEvent): boolean {
  const document: unknown = Bun.YAML.parse(workflowText);

  if (!isRecord(document) || document['on'] === undefined) {
    throw new Error('the workflow has no on');
  }

  const triggers = normalizeTriggers(document['on']);

  if (!(event.name in triggers)) {
    return false;
  }

  const trigger = triggers[event.name] ?? {};

  return match(event)
    .with({ name: 'pull_request' }, (pull) => isPullRequestMatched(trigger, pull))
    .with({ name: 'schedule' }, () => isScheduleSet(trigger))
    .with({ name: 'workflow_dispatch' }, () => true)
    .with({ name: 'workflow_run' }, (run) => isWorkflowRunMatched(trigger, run))
    .exhaustive();
}

function isRecord(value: unknown): value is Readonly<Record<string, unknown>> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

// `on: push`, `on: [push, pull_request]` and a mapping of events to their filters, with an event
// that takes no filter (`workflow_dispatch:`) as an empty mapping
function normalizeTriggers(
  value: unknown,
): Readonly<Record<string, Readonly<Record<string, unknown>> | unknown[]>> {
  if (typeof value === 'string') {
    return { [value]: {} };
  }

  if (Array.isArray(value) && value.every((item) => typeof item === 'string')) {
    return Object.fromEntries(value.map((name: string) => [name, {}]));
  }

  if (!isRecord(value)) {
    throw new Error(`unsupported on: ${JSON.stringify(value)}`);
  }

  return Object.fromEntries(
    Object.entries(value).map((entry: readonly [string, unknown]) => [
      entry[0],
      toTrigger(entry[0], entry[1]),
    ]),
  );
}

function toTrigger(name: string, value: unknown): Readonly<Record<string, unknown>> | unknown[] {
  if (value === null || value === undefined) {
    return {};
  }

  if (isRecord(value) || (name === 'schedule' && Array.isArray(value))) {
    return value;
  }

  throw new Error(`unsupported on.${name}: ${JSON.stringify(value)}`);
}

function isPullRequestMatched(
  trigger: Readonly<Record<string, unknown>> | unknown[],
  event: Extract<ActionsTriggerEvent, { name: 'pull_request' }>,
): boolean {
  const filters = requireModelledFilters('pull_request', trigger, ['branches', 'paths']);
  const branches = findPatterns('pull_request', filters, 'branches');
  const paths = findPatterns('pull_request', filters, 'paths');

  return (
    (branches === undefined || isAnyPatternMatched(branches, event.baseBranch)) &&
    (paths === undefined || event.files.some((file) => isAnyPatternMatched(paths, file)))
  );
}

function requireModelledFilters(
  name: string,
  trigger: Readonly<Record<string, unknown>> | unknown[],
  modelled: readonly string[],
): Readonly<Record<string, unknown>> {
  if (Array.isArray(trigger)) {
    throw new TypeError(`unsupported on.${name}: ${JSON.stringify(trigger)}`);
  }

  const unmodelled = Object.keys(trigger).find((key) => !modelled.includes(key));

  if (unmodelled !== undefined) {
    throw new Error(`unsupported filter: on.${name}.${unmodelled}`);
  }

  return trigger;
}

function findPatterns(
  name: string,
  filters: Readonly<Record<string, unknown>>,
  key: string,
): readonly string[] | undefined {
  const value = filters[key];

  if (value === undefined) {
    return undefined;
  }

  if (!Array.isArray(value) || !value.every((item) => typeof item === 'string')) {
    throw new Error(`unsupported on.${name}.${key}: ${JSON.stringify(value)}`);
  }

  const patterns: readonly string[] = value;
  const negated = patterns.find((pattern) => pattern.startsWith('!'));

  if (negated !== undefined) {
    throw new Error(`unsupported negated pattern: ${negated}`);
  }

  return patterns;
}

// GitHub's `*` matches any characters but `/`, and `**` matches any characters, as Bun.Glob's do
function isAnyPatternMatched(patterns: readonly string[], value: string): boolean {
  return patterns.some((pattern) => new Bun.Glob(pattern).match(value));
}

function isScheduleSet(trigger: Readonly<Record<string, unknown>> | unknown[]): boolean {
  return (
    Array.isArray(trigger) &&
    trigger.some((entry) => isRecord(entry) && typeof entry['cron'] === 'string')
  );
}

function isWorkflowRunMatched(
  trigger: Readonly<Record<string, unknown>> | unknown[],
  event: Extract<ActionsTriggerEvent, { name: 'workflow_run' }>,
): boolean {
  const filters = requireModelledFilters('workflow_run', trigger, [
    'workflows',
    'types',
    'branches',
  ]);

  const workflows = findPatterns('workflow_run', filters, 'workflows') ?? [];

  // GitHub's default activity types for workflow_run are requested and completed
  const types = findPatterns('workflow_run', filters, 'types') ?? ['requested', 'completed'];
  const branches = findPatterns('workflow_run', filters, 'branches');

  return (
    workflows.includes(event.workflow) &&
    types.includes(event.type) &&
    (branches === undefined || isAnyPatternMatched(branches, event.headBranch))
  );
}

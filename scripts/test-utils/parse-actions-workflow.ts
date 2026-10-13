// The parts of a GitHub Actions workflow that decide when its jobs run: each job's needs, `if` and
// concurrency group, and the workflow's group. It throws on concurrency it does not model, so a
// test never passes on a rule the scheduler stand-in ignores.
export interface ActionsConcurrency {
  // lowercased, since GitHub compares group names case-insensitively
  readonly group: string;
}

export interface ActionsJob {
  readonly name: string;
  readonly needs: readonly string[];
  readonly condition: string | undefined;
  readonly concurrency: ActionsConcurrency | undefined;
}

export interface ActionsWorkflow {
  readonly concurrency: ActionsConcurrency | undefined;
  readonly jobs: readonly ActionsJob[];
}

export function parseActionsWorkflow(text: string): ActionsWorkflow {
  const document: unknown = Bun.YAML.parse(text);

  if (!isRecord(document) || !isRecord(document['jobs'])) {
    throw new Error('the workflow has no jobs');
  }

  return {
    concurrency: parseConcurrency(document['concurrency']),
    jobs: Object.entries(document['jobs']).map((entry: readonly [string, unknown]) =>
      parseJob(entry[0], entry[1]),
    ),
  };
}

function isRecord(value: unknown): value is Readonly<Record<string, unknown>> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function parseConcurrency(value: unknown): ActionsConcurrency | undefined {
  if (value === undefined) {
    return undefined;
  }

  const definition = typeof value === 'string' ? { group: value } : value;

  if (!isRecord(definition) || typeof definition['group'] !== 'string') {
    throw new Error(`unsupported concurrency: ${JSON.stringify(value)}`);
  }

  requireModelledConcurrency(definition, definition['group']);

  return { group: definition['group'].toLowerCase() };
}

function requireModelledConcurrency(
  definition: Readonly<Record<string, unknown>>,
  group: string,
): void {
  if (group.includes('${{')) {
    throw new Error(`unsupported concurrency group expression: ${group}`);
  }

  if ((definition['cancel-in-progress'] ?? false) !== false) {
    throw new Error('unsupported concurrency: cancel-in-progress');
  }

  if ((definition['queue'] ?? 'single') !== 'single') {
    throw new Error(`unsupported concurrency queue: ${JSON.stringify(definition['queue'])}`);
  }
}

function parseJob(name: string, definition: unknown): ActionsJob {
  if (!isRecord(definition)) {
    throw new Error(`job ${name} is not a mapping`);
  }

  const needs = definition['needs'] ?? [];
  const condition = definition['if'];

  if (condition !== undefined && typeof condition !== 'string') {
    throw new Error(`job ${name}: unsupported if: ${JSON.stringify(condition)}`);
  }

  if (typeof needs !== 'string' && !isStringArray(needs)) {
    throw new Error(`job ${name}: unsupported needs: ${JSON.stringify(needs)}`);
  }

  return {
    name,
    needs: typeof needs === 'string' ? [needs] : needs,
    condition,
    concurrency: parseConcurrency(definition['concurrency']),
  };
}

function isStringArray(value: unknown): value is readonly string[] {
  return Array.isArray(value) && value.every((item) => typeof item === 'string');
}

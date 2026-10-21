// The parts of a GitHub Actions workflow that decide when its jobs run: each job's needs, `if`,
// concurrency group and outputs, and the workflow's group. It throws on concurrency or an output
// it does not model, so a test never passes on a rule the scheduler stand-in ignores.
export interface ActionsConcurrency {
  // lowercased, since GitHub compares group names case-insensitively
  readonly group: string;

  // how many jobs or runs may wait: one for single, the default, or up to GitHub's cap for max
  readonly queue: 'single' | 'max';
}

// a job output that publishes one step's output, `${{ steps.<step>.outputs.<output> }}`
// a step's output, or the outcome of a step, which continue-on-error leaves apart from its job's
// result
type ActionsJobOutput =
  | { readonly kind: 'output'; readonly step: string; readonly output: string }
  | { readonly kind: 'outcome'; readonly step: string };

export interface ActionsJob {
  readonly name: string;
  readonly needs: readonly string[];
  readonly condition: string | undefined;
  readonly concurrency: ActionsConcurrency | undefined;
  readonly outputs: Readonly<Record<string, ActionsJobOutput>>;
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

  return { group: definition['group'].toLowerCase(), queue: parseQueue(definition['queue']) };
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
}

function parseQueue(value: unknown): ActionsConcurrency['queue'] {
  const queue = value ?? 'single';

  if (queue !== 'single' && queue !== 'max') {
    throw new Error(`unsupported concurrency queue: ${JSON.stringify(value)}`);
  }

  return queue;
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
    outputs: parseOutputs(name, definition['outputs']),
  };
}

function isStringArray(value: unknown): value is readonly string[] {
  return Array.isArray(value) && value.every((item) => typeof item === 'string');
}

const stepOutput =
  /^\$\{\{\s*steps\.(?<step>[A-Za-z_][\w-]*)\.(?:outputs\.(?<output>[A-Za-z_][\w-]*)|(?<outcome>outcome))\s*\}\}$/u;

function parseOutputs(job: string, value: unknown): Record<string, ActionsJobOutput> {
  if (value === undefined) {
    return {};
  }

  if (!isRecord(value)) {
    throw new Error(`job ${job}: unsupported outputs: ${JSON.stringify(value)}`);
  }

  return Object.fromEntries(
    Object.entries(value).map((entry: readonly [string, unknown]) => {
      const groups = typeof entry[1] === 'string' ? stepOutput.exec(entry[1])?.groups : undefined;
      const step = groups?.['step'];
      const output = groups?.['output'];

      if (step === undefined) {
        throw new Error(`job ${job}: unsupported output ${entry[0]}: ${JSON.stringify(entry[1])}`);
      }

      const source: ActionsJobOutput =
        output === undefined ? { kind: 'outcome', step } : { kind: 'output', step, output };

      return [entry[0], source];
    }),
  );
}

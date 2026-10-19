import { readFile, readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { findJSONField } from './find-json-field.ts';

export interface CheckWorkflowStepsOptions {
  readonly args: readonly string[];
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

const usage = 'usage: check-workflow-steps.ts [repo root]\n';

export async function checkWorkflowSteps(
  options: Readonly<CheckWorkflowStepsOptions>,
): Promise<number> {
  if (options.args.length > 1) {
    options.printErr(usage);

    return 2;
  }

  const root = options.args[0] ?? '.';

  const steps = await loadRunSteps(join(root, '.github', 'workflows'));
  const scripts = await loadScriptNames(join(root, 'package.json'));

  const violations = collectViolations(steps, scripts);

  return printReport(violations, steps.length, options);
}

interface RunStep {
  readonly file: string;
  readonly job: string;
  readonly name: string;
  readonly run: unknown;
}

async function loadRunSteps(workflowDir: string): Promise<RunStep[]> {
  const names = await readdir(workflowDir);

  const files = names.filter((name) => name.endsWith('.yml') || name.endsWith('.yaml')).toSorted();
  const paths = files.map((file) => join(workflowDir, file));

  const texts = await Promise.all(paths.map((path) => readFile(path, 'utf8')));

  return files.flatMap((file, index) => collectRunSteps(file, texts[index] ?? ''));
}

function collectRunSteps(file: string, text: string): RunStep[] {
  const workflow: unknown = Bun.YAML.parse(text);
  const jobs = findJSONField(workflow, 'jobs');

  if (typeof jobs !== 'object' || jobs === null) {
    return [];
  }

  return Object.entries(jobs).flatMap((entry: readonly [string, unknown]) =>
    collectJobRunSteps(file, entry[0], entry[1]),
  );
}

function collectJobRunSteps(file: string, job: string, definition: unknown): RunStep[] {
  const steps = findJSONField(definition, 'steps');

  if (!Array.isArray(steps)) {
    return [];
  }

  return steps.flatMap((step: unknown, index: number) => {
    const run = findJSONField(step, 'run');
    const name = formatStepName(findJSONField(step, 'name'), index);

    return run === undefined ? [] : [{ file, job, name, run }];
  });
}

function formatStepName(name: unknown, index: number): string {
  return typeof name === 'string' ? `"${name}"` : `#${index + 1}`;
}

async function loadScriptNames(path: string): Promise<readonly string[]> {
  const text = await readFile(path, 'utf8');

  const manifest: unknown = JSON.parse(text);
  const scripts = findJSONField(manifest, 'scripts');
  const names = typeof scripts === 'object' && scripts !== null ? Object.keys(scripts) : [];

  return names;
}

function collectViolations(steps: readonly RunStep[], scripts: readonly string[]): string[] {
  return steps.flatMap((step) => {
    const reason = findViolation(step.run, scripts);

    return reason === undefined
      ? []
      : [`.github/workflows/${step.file}: job ${step.job}, step ${step.name}: ${reason}\n`];
  });
}

function findViolation(run: unknown, scripts: readonly string[]): string | undefined {
  if (typeof run !== 'string') {
    return 'run is not a string';
  }

  const command = run.trim();

  if (command.includes('\n')) {
    return 'runs more than one line';
  }

  if (command.includes(`\${{`)) {
    return `interpolates a \${{ }} expression; pass it through env instead`;
  }

  return command === 'bun install --frozen-lockfile'
    ? undefined
    : findCallViolation(command, scripts);
}

const scriptCall = /^bun run (?:--silent )?(?<script>[a-z][a-z0-9:-]*)(?<args>(?: \S+)*)$/u;

function findCallViolation(command: string, scripts: readonly string[]): string | undefined {
  const call = scriptCall.exec(command);
  const script = call?.groups?.['script'];

  if (script === undefined) {
    return `runs \`${command}\`, not one bun run call`;
  }

  if (!scripts.includes(script)) {
    return `calls ${script}, which the root package.json does not define`;
  }

  return findArgViolation(call?.groups?.['args'] ?? '');
}

const plainArg = /^(?:[\w@%+=:,./~-]+|'[^']*'|"\$[A-Za-z_]\w*")$/u;

function findArgViolation(args: string): string | undefined {
  const words = args.split(' ').filter((word) => word !== '');
  const badArg = words.find((word) => !plainArg.test(word));

  return badArg === undefined
    ? undefined
    : `passes ${badArg}, which is not a plain word, a quoted literal or one "$VARIABLE"`;
}

function printReport(
  violations: readonly string[],
  checked: number,
  options: Readonly<CheckWorkflowStepsOptions>,
): number {
  if (violations.length > 0) {
    options.printErr(violations.join(''));

    options.printErr(
      `check-workflow-steps: ${violations.length} of ${checked} run steps are not one bun run call\n`,
    );

    return 1;
  }

  options.printOut(`check-workflow-steps: ${checked} run steps, each one bun run call\n`);

  return 0;
}

if (import.meta.main) {
  process.exitCode = await checkWorkflowSteps({
    args: process.argv.slice(2),
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}

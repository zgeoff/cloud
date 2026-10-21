import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { findJSONField } from './find-json-field.ts';

export interface CheckWorkflowConcurrencyOptions {
  readonly args: readonly string[];
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

const usage = 'usage: check-workflow-concurrency.ts [repo root]\n';

export async function checkWorkflowConcurrency(
  options: Readonly<CheckWorkflowConcurrencyOptions>,
): Promise<number> {
  if (options.args.length > 1) {
    options.printErr(usage);

    return 2;
  }

  const workflowDir = join(options.args[0] ?? '.', '.github', 'workflows');

  const ci = await readWorkflow(join(workflowDir, 'ci.yml'));
  const deploy = await readWorkflow(join(workflowDir, 'deploy-prod.yml'));

  const apply = findJSONField(findJSONField(deploy, 'jobs'), 'apply');

  const violations = [
    ...collectCIViolations(findJSONField(ci, 'concurrency')),
    ...collectDeployViolations(findJSONField(apply, 'concurrency')),
  ];

  if (violations.length > 0) {
    options.printErr(violations.map((violation) => `${violation}\n`).join(''));

    return 1;
  }

  options.printOut(
    "check-workflow-concurrency: a push to main cancels main's earlier CI run, and never an apply\n",
  );

  return 0;
}

async function readWorkflow(path: string): Promise<unknown> {
  const text = await readFile(path, 'utf8');

  const workflow: unknown = Bun.YAML.parse(text);

  return workflow;
}

// a value that differs between two runs on the same branch gives each push its own group, which
// no later push cancels
const perRunValues = ['github.sha', 'github.run_id', 'github.run_number', 'github.run_attempt'];

function collectCIViolations(concurrency: unknown): string[] {
  const group = findJSONField(concurrency, 'group');

  const perRun =
    typeof group === 'string' ? perRunValues.find((value) => group.includes(value)) : undefined;

  return [
    ...(typeof group === 'string' ? [] : ['ci.yml: the workflow has no concurrency group']),
    ...(perRun === undefined
      ? []
      : [`ci.yml: the concurrency group holds ${perRun}, so pushes to main never share it`]),
    ...(findJSONField(concurrency, 'cancel-in-progress') === true
      ? []
      : [
          'ci.yml: cancel-in-progress is not true, so a push to main never cancels the earlier run',
        ]),
  ];
}

function collectDeployViolations(concurrency: unknown): string[] {
  const group = findJSONField(concurrency, 'group');

  return [
    ...(typeof group === 'string' && !group.includes(`\${{`)
      ? []
      : ['deploy-prod.yml: the apply job has no fixed concurrency group of its own']),
    ...(findJSONField(concurrency, 'cancel-in-progress') === false
      ? []
      : [
          "deploy-prod.yml: the apply job's cancel-in-progress is not false, so a new run can cancel an apply",
        ]),
  ];
}

if (import.meta.main) {
  process.exitCode = await checkWorkflowConcurrency({
    args: process.argv.slice(2),
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}

import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { findJSONField } from '../find-json-field.ts';
import { runProcess } from '../run-process.ts';
import type { ActionsTemplateContext } from './render-actions-template.ts';
import { renderActionsTemplate } from './render-actions-template.ts';

// Runs one `run` step of a parsed workflow as a Linux runner does, per GitHub's "Workflow syntax"
// (jobs.<job_id>.steps[*].run, shell bash -e {0}) and "Workflow commands" (GITHUB_OUTPUT): the
// job's env, then the step's, rendered against the context, in the step's working directory.
export interface RunActionsStepOptions {
  // the step's and the job's mappings from the parsed workflow; a job with no env passes undefined
  readonly step: unknown;
  readonly jobEnv: unknown;
  readonly context: Readonly<ActionsTemplateContext>;

  // the workspace the step runs in, and a directory for its HOME and its step files
  readonly cwd: string;
  readonly directory: string;
  readonly path: string;
}

export interface ActionsStepResult {
  readonly status: 'success' | 'failure';
  readonly outputs: Readonly<Record<string, string>>;
  readonly stdout: string;
  readonly summary: string;
}

export async function runActionsStep(
  options: Readonly<RunActionsStepOptions>,
): Promise<ActionsStepResult> {
  const run = findJSONField(options.step, 'run');

  if (typeof run !== 'string' || findJSONField(options.step, 'uses') !== undefined) {
    throw new Error('the step is not a run step');
  }

  const output = join(options.directory, 'output');
  const summary = join(options.directory, 'summary');

  await writeFile(output, '');
  await writeFile(summary, '');

  const result = await runProcess(['bash', '--noprofile', '--norc', '-e', '-c', run], {
    cwd: join(options.cwd, getWorkingDirectory(options.step)),
    env: {
      ...renderEnv(options.jobEnv, options.context),
      ...renderEnv(findJSONField(options.step, 'env'), options.context),
      PATH: options.path,
      HOME: options.directory,
      GITHUB_OUTPUT: output,
      GITHUB_STEP_SUMMARY: summary,
    },
  });

  const outputText = await readFile(output, 'utf8');
  const summaryText = await readFile(summary, 'utf8');

  return {
    status: result.exitCode === 0 ? 'success' : 'failure',
    outputs: parseOutputs(outputText),
    stdout: result.stdout.toString(),
    summary: summaryText,
  };
}

function getWorkingDirectory(step: unknown): string {
  const directory = findJSONField(step, 'working-directory') ?? '.';

  if (typeof directory !== 'string') {
    throw new TypeError(`unsupported working-directory: ${JSON.stringify(directory)}`);
  }

  return directory;
}

function renderEnv(
  env: unknown,
  context: Readonly<ActionsTemplateContext>,
): Record<string, string> {
  if (env === undefined) {
    return {};
  }

  if (typeof env !== 'object' || env === null || Array.isArray(env)) {
    throw new TypeError(`unsupported env: ${JSON.stringify(env)}`);
  }

  return Object.fromEntries(
    Object.entries(env).map((entry: readonly [string, unknown]) => [
      entry[0],
      renderActionsTemplate(entry[1], context),
    ]),
  );
}

// `name=value` lines only; the multiline `name<<delimiter` form throws, since no step here uses it
function parseOutputs(text: string): Record<string, string> {
  return Object.fromEntries(
    text
      .split('\n')
      .filter((line: string) => line !== '')
      .map((line: string) => {
        const separator = line.indexOf('=');

        if (separator < 1) {
          throw new Error(`unsupported output line: ${line}`);
        }

        return [line.slice(0, separator), line.slice(separator + 1)];
      }),
  );
}

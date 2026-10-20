import { appendFile } from 'node:fs/promises';
import type { Runner } from '../run-process.ts';
import { runProcess } from '../run-process.ts';
import { readReleaseBumps } from './read-release-bumps.ts';

export interface RunWriteReleaseBumpsOptions {
  readonly env: Readonly<Record<string, string | undefined>>;

  readonly root: string;
  readonly run: Runner;
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

export async function runWriteReleaseBumps(
  options: Readonly<RunWriteReleaseBumpsOptions>,
): Promise<number> {
  const files = findStepFiles(options.env);

  if (files instanceof Error) {
    options.printErr(`${files.message}\n`);

    return 2;
  }

  const bumps = await readReleaseBumps(options.root, options.run);

  if (bumps instanceof Error) {
    options.printErr(`${bumps.message}\n`);

    return 1;
  }

  await writeBumps(options, files, bumps);

  return 0;
}

interface StepFiles {
  readonly output: string;
  readonly summary: string;
}

function findStepFiles(env: Readonly<Record<string, string | undefined>>): StepFiles | Error {
  const output = env['GITHUB_OUTPUT'] ?? '';
  const summary = env['GITHUB_STEP_SUMMARY'] ?? '';
  const missing = output === '' ? 'GITHUB_OUTPUT' : 'GITHUB_STEP_SUMMARY';

  return output === '' || summary === ''
    ? new Error(`${missing} must be set, as the workflow's runner sets it`)
    : { output, summary };
}

async function writeBumps(
  options: Readonly<RunWriteReleaseBumpsOptions>,
  files: StepFiles,
  bumps: readonly string[],
) {
  const text = renderSummary(bumps);

  // no output skips the bump job
  if (bumps.length > 0) {
    await appendFile(files.output, `bumps<<EOF\n${bumps.join('\n')}\nEOF\n`);
  }

  await appendFile(files.summary, text);

  options.printOut(text);
}

function renderSummary(bumps: readonly string[]) {
  if (bumps.length === 0) {
    return 'Every pin holds its newest release.\n';
  }

  const items = bumps.map((bump) => `- ${bump}\n`).join('');

  return `Pins older than their newest release (dependency, newest, pinned):\n\n${items}`;
}

if (import.meta.main) {
  process.exitCode = await runWriteReleaseBumps({
    env: process.env,
    root: process.cwd(),
    run: runProcess,
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}

import { mkdir, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import type { StubAnswer, StubCall, StubHandler } from './build-stub-runner.ts';

// Stands in for infra/cluster/write-restore-jobs.ts, which the release bump runs from the checkout
// root, checked against that script on 2026-11-07: it writes each restore Job that differs and
// prints `write-restore-jobs: wrote <path>` for it, or exits 1 with its error on stderr
export interface StubWriteRestoreJobsScenario {
  // each restore Job it writes, by its path from the root
  readonly jobs?: Readonly<Record<string, string>>;
  readonly error?: string;
}

export function buildStubWriteRestoreJobs(scenario: StubWriteRestoreJobsScenario): StubHandler {
  const answerCall: StubHandler = (call) =>
    isRestoreJobsWrite(call) ? writeJobs(scenario, call) : undefined;

  return answerCall;
}

function isRestoreJobsWrite(call: StubCall) {
  return (
    call.options.cwd !== undefined &&
    call.argv.length === 2 &&
    call.argv[0] === 'bun' &&
    call.argv[1] === 'infra/cluster/write-restore-jobs.ts'
  );
}

async function writeJobs(
  scenario: StubWriteRestoreJobsScenario,
  call: StubCall,
): Promise<StubAnswer> {
  if (scenario.error !== undefined) {
    return { exitCode: 1, stderr: `write-restore-jobs: ${scenario.error}\n` };
  }

  const jobs = Object.entries(scenario.jobs ?? {});

  for (const [path, text] of jobs) {
    const file = join(call.options.cwd ?? '', path);

    await mkdir(dirname(file), { recursive: true });
    await writeFile(file, text);
  }

  return { stdout: jobs.map(([path]) => `write-restore-jobs: wrote ${path}\n`).join('') };
}

import { runProcess } from '../run-process.ts';
import { runGitSteps } from './run-git-steps.ts';
import { runReleaseBump } from './run-release-bump.ts';
import type { BumpContext } from './types.ts';

// The release check's bump job step: it opens or updates the bump pull request for each line of
// BUMPS, the check job's output. Every line runs, from a clean tree, so one dependency's failure
// leaves the others' pull requests current; any failure fails the step once all have run.
export async function runReleaseBumps(context: BumpContext): Promise<number> {
  const bumps = (context.env['BUMPS'] ?? '').split('\n').filter((line) => line.trim() !== '');

  if (bumps.length === 0) {
    context.printErr("BUMPS must be set, as the check job's output sets it\n");

    return 2;
  }

  let failed = 0;

  for (const bump of bumps) {
    const status = await runGroupedBump(context, bump.trim().split(/\s+/u));

    failed = status === 0 ? failed : 1;
  }

  return failed;
}

// runs one bump in its own collapsed log group, after a reset: a failed pin can leave tracked
// files changed, and every bump starts from a clean tree
async function runGroupedBump(context: BumpContext, line: readonly string[]) {
  const [dependency = '', version = ''] = line;

  context.printOut(`::group::${dependency} ${version}\n`);

  const reset = await runGitSteps(context, [
    ['reset', '-q', '--hard'],
    ['clean', '-fdq'],
  ]);

  const status =
    reset === undefined ? await runReleaseBump(context, line) : printError(context, reset);

  if (status !== 0) {
    context.printOut(`::error::the ${dependency} bump failed\n`);
  }

  context.printOut('::endgroup::\n');

  return status;
}

function printError(context: BumpContext, error: Readonly<Error>) {
  context.printErr(`${error.message}\n`);

  return 1;
}

if (import.meta.main) {
  process.exitCode = await runReleaseBumps({
    cwd: process.cwd(),
    env: process.env,
    run: runProcess,
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}

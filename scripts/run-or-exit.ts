import { ExitError } from './exit-error.ts';
import type { RunOptions, RunResult, Runner } from './run-process.ts';

export interface ScriptIO {
  readonly run: Runner;
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

// Runs one command as a `set -e` line does: its stderr passes through, and a failure stops the
// script with the command's exit code. A timeout stops it with 124, as `timeout` exits.
export async function runOrExit(
  io: Readonly<ScriptIO>,
  argv: readonly string[],
  options?: Readonly<RunOptions>,
): Promise<RunResult> {
  const result = await io.run(argv, options);

  if (result.stderr.length > 0) {
    io.printErr(result.stderr.toString());
  }

  if (result.timedOut) {
    throw new ExitError(124, `${argv[0] ?? ''} timed out`);
  }

  if (result.exitCode !== 0) {
    throw new ExitError(result.exitCode, '');
  }

  return result;
}

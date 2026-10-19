import { ExitError } from './exit-error.ts';
import type { RunOptions, RunResult, Runner } from './run-process.ts';

export interface ScriptIO {
  readonly run: Runner;
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

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

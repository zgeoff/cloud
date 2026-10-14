import { ExitError } from './exit-error.ts';

// Runs a script's body and turns an ExitError into its exit code, as `set -e` turns a failed
// command into the script's exit status. Any other error is a bug, so it propagates.
export async function withExitCode(
  printErr: (text: string) => void,
  body: () => Promise<number>,
): Promise<number> {
  try {
    return await body();
  } catch (error) {
    if (!(error instanceof ExitError)) {
      throw error;
    }

    if (error.message !== '') {
      printErr(`${error.message}\n`);
    }

    return error.exitCode;
  }
}

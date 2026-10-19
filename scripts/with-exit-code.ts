import { ExitError } from './exit-error.ts';

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

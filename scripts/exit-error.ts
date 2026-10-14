// A script's stop: withExitCode prints the message, which may be empty when the failed tool has
// already said why, and returns the exit code
export class ExitError extends Error {
  readonly exitCode: number;

  constructor(exitCode: number, message: string) {
    super(message);

    this.name = 'ExitError';
    this.exitCode = exitCode;
  }
}

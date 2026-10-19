// The message may be empty when the failed tool has already said why.
export class ExitError extends Error {
  readonly exitCode: number;

  constructor(exitCode: number, message: string) {
    super(message);

    this.name = 'ExitError';
    this.exitCode = exitCode;
  }
}

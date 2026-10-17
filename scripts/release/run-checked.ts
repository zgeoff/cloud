import type { RunOptions, Runner } from '../run-process.ts';

// runs the program and gives its stdout, or an Error that carries its stderr and exit code
export async function runChecked(
  run: Runner,
  argv: readonly string[],
  options: Readonly<RunOptions> = {},
): Promise<string | Error> {
  const result = await run(argv, options);

  if (result.exitCode !== 0) {
    const stderr = result.stderr.toString().trim();
    const message = stderr === '' ? `${argv.join(' ')} exited ${result.exitCode}` : stderr;

    return new Error(message);
  }

  return result.stdout.toString();
}

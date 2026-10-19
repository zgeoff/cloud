import type { RunOptions, Runner } from '../run-process.ts';

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

import { runProcess } from '../run-process.ts';
import type { StubHandler } from './build-stub-runner.ts';

// Hands each call to one of the named programs to the real runProcess, for a test that lets a
// local tool such as tar or git run for real beside the stand-ins; its output must be text. A
// call that sets no env runs with the given one, so git can run without the user's config.
export function buildRealProgramHandler(
  programs: readonly string[],
  env?: Readonly<Record<string, string>>,
): StubHandler {
  return async (call) => {
    if (!programs.includes(call.argv[0] ?? '')) {
      return;
    }

    const result = await runProcess(call.argv, { ...call.options, env: call.options.env ?? env });

    return {
      exitCode: result.exitCode,
      stdout: result.stdout.toString(),
      stderr: result.stderr.toString(),
      timedOut: result.timedOut,
    };
  };
}

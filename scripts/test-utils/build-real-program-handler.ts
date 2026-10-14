import { runProcess } from '../run-process.ts';
import type { StubCall, StubHandler } from './build-stub-runner.ts';

// Hands each call to one of the named programs to the real runProcess, for a test that lets a
// local tool such as tar or git run for real beside the stand-ins; its output must be text. A
// call that sets no env runs with the given one, so git can run without the user's config.
export function buildRealProgramHandler(
  programs: readonly string[],
  env?: Readonly<Record<string, string>>,
): StubHandler {
  return (call) => (programs.includes(call.argv[0] ?? '') ? runReal(call, env) : undefined);
}

async function runReal(call: StubCall, env?: Readonly<Record<string, string>>) {
  const envOf = call.options.env ?? env;
  const stdin = call.stdin === '' ? {} : { stdin: Buffer.from(call.stdin) };
  const options = { ...call.options, ...stdin, ...(envOf === undefined ? {} : { env: envOf }) };

  const result = await runProcess(call.argv, options);

  return {
    exitCode: result.exitCode,
    stdout: result.stdout.toString(),
    stderr: result.stderr.toString(),
    timedOut: result.timedOut,
  };
}

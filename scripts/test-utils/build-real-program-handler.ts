import { runProcess } from '../run-process.ts';
import type { StubCall, StubHandler } from './build-stub-runner.ts';

export function buildRealProgramHandler(
  programs: readonly string[],
  env?: Readonly<Record<string, string>>,
): StubHandler {
  return (call) => (programs.includes(call.argv[0] ?? '') ? runReal(call, env) : undefined);
}

async function runReal(call: StubCall, env?: Readonly<Record<string, string>>) {
  // a call that sets no env runs with the given one, so git can run without the user's config
  const envOf = call.options.env ?? env;
  const stdin = call.stdin === '' ? {} : { stdin: Buffer.from(call.stdin) };
  const options = { ...call.options, ...stdin, ...(envOf === undefined ? {} : { env: envOf }) };

  const result = await runProcess(call.argv, options);

  return {
    exitCode: result.exitCode,

    // a called program's output must be text
    stdout: result.stdout.toString(),
    stderr: result.stderr.toString(),
    timedOut: result.timedOut,
  };
}

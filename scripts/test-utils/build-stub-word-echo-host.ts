import { runProcess } from '../run-process.ts';
import type { StubAnswer, StubCall, StubHandler } from './build-stub-runner.ts';

// Stands in for ssh to a host whose shell prints each word it parses from the remote line, in
// brackets, one to a line, so a word that split prints as two. Real local bash parses the line
// behind `printf '[%s]\n'`, with only PATH set, so nothing but printf runs.
export function buildStubWordEchoHost(): StubHandler {
  return (call) => (call.argv[0] === 'ssh' ? runWordEcho(call) : undefined);
}

async function runWordEcho(call: StubCall): Promise<StubAnswer> {
  const line = call.argv.at(-1) ?? '';

  const result = await runProcess(['bash', '-c', `printf '[%s]\\n' ${line}`], {
    env: { PATH: '/usr/bin:/bin' },
  });

  return {
    exitCode: result.exitCode,
    stdout: result.stdout.toString(),
    stderr: result.stderr.toString(),
  };
}

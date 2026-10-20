import { runProcess } from '../run-process.ts';
import type { StubAnswer, StubCall, StubHandler } from './build-stub-runner.ts';

export function buildStubWordEchoHost(): StubHandler {
  return answerCall;
}

function answerCall(call: StubCall) {
  return call.argv[0] === 'ssh' ? runWordEcho(call) : undefined;
}

async function runWordEcho(call: StubCall): Promise<StubAnswer> {
  const line = call.argv.at(-1) ?? '';

  // real bash parses the line, so a word that split prints as two; with only PATH set, nothing but
  // printf runs
  const result = await runProcess(['bash', '-c', `printf '[%s]\\n' ${line}`], {
    env: { PATH: '/usr/bin:/bin' },
  });

  return {
    exitCode: result.exitCode,
    stdout: result.stdout.toString(),
    stderr: result.stderr.toString(),
  };
}

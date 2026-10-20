import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import type { StubAnswer, StubCall, StubHandler } from './build-stub-runner.ts';

export interface StubNixieAPIContractScenario {
  readonly error?: string;
}

export function buildStubNixieAPIContract(scenario: StubNixieAPIContractScenario): StubHandler {
  const answerCall: StubHandler = (call) =>
    isContractCall(call) ? writeContract(scenario, call) : undefined;

  return answerCall;
}

const script = 'scripts/nixie-api/write-nixie-api-contract.ts';

function isContractCall(call: StubCall) {
  const cwd = call.options.cwd;

  return (
    cwd !== undefined &&
    call.argv.length === 3 &&
    call.argv[0] === 'bun' &&
    call.argv[1] === join(cwd, script)
  );
}

async function writeContract(
  scenario: StubNixieAPIContractScenario,
  call: StubCall,
): Promise<StubAnswer> {
  if (scenario.error !== undefined) {
    return { exitCode: 1, stderr: `${scenario.error}\n` };
  }

  const tag = call.argv[2] ?? '';
  const directory = join(call.options.cwd ?? '', 'scripts/nixie-api');

  await writeFile(join(directory, 'openapi.json'), `{"info":{"version":"${tag}"}}\n`);
  await writeFile(join(directory, 'openapi.d.ts'), `// nixie ${tag}\n`);

  return { stdout: `write-nixie-api-contract: wrote nixie ${tag}'s openapi.json and its types\n` };
}

import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import type { StubAnswer, StubCall, StubHandler } from './build-stub-runner.ts';

// Stands in for `bun <checkout>/scripts/nixie-api/write-nixie-api-contract.ts <tag>`, run from the
// checkout's root. It writes a marked openapi.json and openapi.d.ts where the real script writes
// them, and prints its line; with an error, it fails with exit 1 and writes nothing.
export interface StubNixieAPIContractScenario {
  readonly error?: string;
}

const script = 'scripts/nixie-api/write-nixie-api-contract.ts';

export function buildStubNixieAPIContract(scenario: StubNixieAPIContractScenario): StubHandler {
  return (call) => (isContractCall(call) ? writeContract(scenario, call) : undefined);
}

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

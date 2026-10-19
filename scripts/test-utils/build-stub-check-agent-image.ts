import { existsSync } from 'node:fs';
import type { StubAnswer, StubHandler } from './build-stub-runner.ts';

export function buildStubCheckAgentImage(failures: number): StubHandler {
  return (call) => {
    const [program = '', script = '', flag, name] = call.argv;

    const isCheck =
      ((program === 'bun' && script.endsWith('/scripts/check-agent-image.ts')) ||
        (program === 'bash' && script.endsWith('/scripts/check-agent-image.sh'))) &&
      flag === '--imp' &&
      name !== undefined &&
      call.argv.length === 4;

    const answer: StubAnswer = {
      exitCode: failures === 0 ? 0 : 1,
      stdout: `== ${failures} failed\n`,
    };

    // answering only when the script exists proves the build ran the archive's copy
    return isCheck && existsSync(script) ? answer : undefined;
  };
}

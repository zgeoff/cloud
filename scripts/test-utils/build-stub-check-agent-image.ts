import { existsSync } from 'node:fs';
import type { StubAnswer, StubHandler } from './build-stub-runner.ts';

// Stands in for the commit's own check that build-agent-image.ts runs with bun, or with bash for an
// older commit. It answers only when the script exists, so a test proves the build ran the
// archive's copy, and prints the failure count as the real check's last line.
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

    return isCheck && existsSync(script) ? answer : undefined;
  };
}

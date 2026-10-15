import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { toShellArg } from '../to-shell-arg.ts';

// Writes <bin>/docker, a stand-in for docker running the impz CLI in imp-host at the one call
// scripts/host/mint-atc-imp-token.sh makes; it logs each call's argv as a JSON line to
// <bin>/docker-calls, and any other call ends with exit 97 and "unexpected: <argv>" on stderr.
export interface StubImpDockerAnswer {
  readonly stdout: string;
  readonly stderr: string;
  readonly exitCode: number;
}

export async function createStubImpDocker(
  bin: string,
  answer: Readonly<StubImpDockerAnswer>,
): Promise<string> {
  const path = join(bin, 'docker');

  // imp 1.0.0 prints a new token's secret alone on stdout, after a notice on stderr, and exits 1
  // when it fails (packages/cli/src/commands/tokens.ts and run-action.ts at 4211437b)
  const script = `#!/usr/bin/env bash
printf '%s\\0' docker "$@" | jq -cRs 'split("\\u0000")[:-1]' >> ${toShellArg(join(bin, 'docker-calls'))}
if [ "$*" != "exec imp-host impz token new atc-cloud --scope manage --imps harness-* --grantable glm" ]; then
  echo "unexpected: $*" >&2
  exit 97
fi
printf '%s' ${toShellArg(answer.stdout)}
printf '%s' ${toShellArg(answer.stderr)} >&2
exit ${answer.exitCode}
`;

  await writeFile(path, script, { mode: 0o755 });

  return path;
}

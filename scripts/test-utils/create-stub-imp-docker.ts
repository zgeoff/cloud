import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { toShellArg } from '../to-shell-arg.ts';

export interface StubImpDockerAnswer {
  readonly stdout: string;
  readonly stderr: string;
  readonly exitCode: number;
}

const mintCall = [
  'exec',
  'imp-host',
  'impz',
  'token',
  'new',
  'atc-cloud',
  '--scope',
  'manage',
  '--imps',
  'harness-*',
  '--grantable',
  'glm,claude-setup-token,github-imp-agents,linear-imp-agents,op-connect',
];

export async function createStubImpDocker(
  bin: string,
  answer: Readonly<StubImpDockerAnswer>,
  call: readonly string[] = mintCall,
): Promise<string> {
  const path = join(bin, 'docker');
  const expected = JSON.stringify(['docker', ...call]);

  // imp 1.0.0 prints a new token's secret alone on stdout, after a notice on stderr, and exits 1
  // when it fails (packages/cli/src/commands/tokens.ts and run-action.ts at 4211437b)
  const script = `#!/usr/bin/env bash
argv="$(printf '%s\\0' docker "$@" | jq -cRs 'split("\\u0000")[:-1]')"
printf '%s\\n' "$argv" >> ${toShellArg(join(bin, 'docker-calls'))}
jq -cn '{IMP_TOKEN: env.IMP_TOKEN, IMP_URL: env.IMP_URL}' >> ${toShellArg(join(bin, 'docker-env'))}
if [ "$argv" != ${toShellArg(expected)} ]; then
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

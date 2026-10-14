import { ExitError } from './exit-error.ts';
import type { ScriptIO } from './run-or-exit.ts';
import { runOrExit } from './run-or-exit.ts';

export interface ATCPinBranch {
  // the branch's commit on origin, for the push's lease; empty when the branch does not exist
  readonly lease: string;

  // the atc release the branch's Dockerfile pins; empty when the branch does not exist
  readonly version: string;
}

// Reads origin's atc-pin/agent-image branch, which the pin pull request comes from
export async function readATCPinBranch(
  io: Readonly<ScriptIO>,
  cwd: string,
  branch: string,
): Promise<ATCPinBranch> {
  const ref = `refs/heads/${branch}`;

  const exists = await hasRemoteBranch(io, cwd, ref);

  if (!exists) {
    return { lease: '', version: '' };
  }

  await runOrExit(io, ['git', 'fetch', '-q', 'origin', ref], { cwd });

  const head = await runOrExit(io, ['git', 'rev-parse', 'FETCH_HEAD'], { cwd });

  const dockerfile = await runOrExit(io, ['git', 'show', 'FETCH_HEAD:images/agent/Dockerfile'], {
    cwd,
  });

  const match = /^ARG ATC_VERSION=(?<version>.*)$/mu.exec(dockerfile.stdout.toString());

  return { lease: head.stdout.toString().trim(), version: match?.groups?.version ?? '' };
}

// git ls-remote --exit-code exits 2 when no ref matches
async function hasRemoteBranch(io: Readonly<ScriptIO>, cwd: string, ref: string) {
  const listed = await io.run(['git', 'ls-remote', '--exit-code', '--heads', 'origin', ref], {
    cwd,
  });

  if (listed.exitCode !== 0 && listed.exitCode !== 2) {
    io.printErr(listed.stderr.toString());
    throw new ExitError(listed.exitCode, '');
  }

  return listed.exitCode === 0;
}

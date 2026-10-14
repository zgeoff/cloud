import { existsSync } from 'node:fs';
import { join } from 'node:path';
import type { ScriptIO } from './run-or-exit.ts';
import { runOrExit } from './run-or-exit.ts';

export interface AgentImageCheck {
  readonly image: string;

  // the imp the check boots from the image
  readonly check: string;

  // the commit's extracted image and scripts, and the work directory that holds them
  readonly src: string;
  readonly work: string;
}

// the check downloads gitleaks and sweeps the whole image, so it gets longer than a call's default
const checkTimeoutMs = 1_800_000;

// Runs the commit's own check on a fresh imp from the image, then removes the imp, passing every
// output on to stderr. Returns whether the check passed. A commit from before the check moved to
// Bun has only check-agent-image.sh.
export async function runAgentImageCheck(
  io: Readonly<ScriptIO>,
  target: Readonly<AgentImageCheck>,
): Promise<boolean> {
  const created = await runOrExit(io, ['imp', 'new', target.check, '--image', target.image]);

  printErrText(io, created.stdout.toString());

  const script = join(target.src, 'scripts/check-agent-image.ts');

  const argv = existsSync(script)
    ? ['bun', script, '--imp', target.check]
    : ['bash', join(target.src, 'scripts/check-agent-image.sh'), '--imp', target.check];

  const result = await io.run(argv, { cwd: target.work, timeoutMs: checkTimeoutMs });

  printErrText(io, `${result.stdout.toString()}${result.stderr.toString()}`);

  const removed = await runOrExit(io, ['imp', 'rm', target.check]);

  printErrText(io, removed.stdout.toString());

  return result.exitCode === 0 && !result.timedOut;
}

function printErrText(io: Readonly<ScriptIO>, text: string) {
  if (text !== '') {
    io.printErr(text);
  }
}

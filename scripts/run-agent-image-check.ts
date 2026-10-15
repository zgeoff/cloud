import { chmodSync, existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { ScriptIO } from './run-or-exit.ts';
import { runOrExit } from './run-or-exit.ts';
import type { InterruptibleIO } from './subscribe-to-interrupts.ts';

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
  io: Readonly<InterruptibleIO>,
  target: Readonly<AgentImageCheck>,
): Promise<boolean> {
  // registered before `impz new`, since impd can create the imp after an interrupt stops the CLI,
  // and the caller found its name free
  const dropCleanup = io.registerCleanup((cleanupIO) => removeCheckImp(cleanupIO, target.check));

  try {
    return await runCheckOnImp(io, target);
  } finally {
    dropCleanup();
  }
}

async function runCheckOnImp(io: Readonly<ScriptIO>, target: Readonly<AgentImageCheck>) {
  const created = await runOrExit(io, ['impz', 'new', target.check, '--image', target.image]);

  printErrText(io, created.stdout.toString());

  const script = join(target.src, 'scripts/check-agent-image.ts');

  const argv = existsSync(script)
    ? ['bun', script, '--imp', target.check]
    : ['bash', join(target.src, 'scripts/check-agent-image.sh'), '--imp', target.check];

  const env = {
    ...process.env,
    PATH: `${createImpShim(target.work)}:${process.env['PATH'] ?? ''}`,
  };

  const result = await io.run(argv, { cwd: target.work, timeoutMs: checkTimeoutMs, env });

  printErrText(io, `${result.stdout.toString()}${result.stderr.toString()}`);

  await removeCheckImp(io, target.check);

  return result.exitCode === 0 && !result.timedOut;
}

// A commit from before imp's CLI became impz has a check that calls `imp`: the shim on its PATH
// hands each call to impz. Returns the shim's directory, inside the work directory.
function createImpShim(work: string): string {
  const dir = join(work, 'imp-shim');
  const shim = join(dir, 'imp');

  mkdirSync(dir, { recursive: true });
  writeFileSync(shim, '#!/bin/sh\nexec impz "$@"\n');
  chmodSync(shim, 0o755);

  return dir;
}

async function removeCheckImp(io: Readonly<ScriptIO>, check: string) {
  const removed = await runOrExit(io, ['impz', 'rm', check]);

  printErrText(io, removed.stdout.toString());
}

function printErrText(io: Readonly<ScriptIO>, text: string) {
  if (text !== '') {
    io.printErr(text);
  }
}

import { chmodSync, existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { buildImpArgv, impCLI } from './imp-cli.ts';
import type { ScriptIO } from './run-or-exit.ts';
import { runOrExit } from './run-or-exit.ts';
import type { InterruptibleIO } from './subscribe-to-interrupts.ts';

export interface AgentImageCheck {
  readonly image: string;

  readonly check: string;

  readonly source: string;
  readonly work: string;
}

// the check downloads gitleaks and sweeps the whole image, so it gets longer than a call's default
const checkTimeoutMs = 1_800_000;

export async function runAgentImageCheck(
  io: Readonly<InterruptibleIO>,
  target: Readonly<AgentImageCheck>,
): Promise<boolean> {
  // registered before the CLI's `new`, since impd can create the imp after an interrupt stops the CLI,
  // and the caller found its name free
  const dropCleanup = io.registerCleanup((cleanupIO) => removeCheckImp(cleanupIO, target.check));

  try {
    return await runCheckOnImp(io, target);
  } finally {
    dropCleanup();
  }
}

async function runCheckOnImp(io: Readonly<ScriptIO>, target: Readonly<AgentImageCheck>) {
  const created = await runOrExit(io, buildImpArgv(['new', target.check, '--image', target.image]));

  printErrText(io, created.stdout.toString());

  const script = join(target.source, 'scripts/check-agent-image.ts');

  // a commit from before the check moved to Bun has only the shell check
  const argv = existsSync(script)
    ? ['bun', script, '--imp', target.check]
    : ['bash', join(target.source, 'scripts/check-agent-image.sh'), '--imp', target.check];

  const env = {
    ...process.env,
    PATH: `${createImpShim(target.work)}:${process.env['PATH'] ?? ''}`,
  };

  const result = await io.run(argv, { cwd: target.work, timeoutMs: checkTimeoutMs, env });

  printErrText(io, `${result.stdout.toString()}${result.stderr.toString()}`);

  await removeCheckImp(io, target.check);

  return result.exitCode === 0 && !result.timedOut;
}

function createImpShim(work: string): string {
  // a commit from before imp's CLI took its new name has a check that calls `imp`
  const directory = join(work, 'imp-shim');
  const shim = join(directory, 'imp');

  mkdirSync(directory, { recursive: true });
  writeFileSync(shim, `#!/bin/sh\nexec ${impCLI} "$@"\n`);
  chmodSync(shim, 0o755);

  return directory;
}

async function removeCheckImp(io: Readonly<ScriptIO>, check: string) {
  const removed = await runOrExit(io, buildImpArgv(['rm', check]));

  printErrText(io, removed.stdout.toString());
}

function printErrText(io: Readonly<ScriptIO>, text: string) {
  if (text !== '') {
    io.printErr(text);
  }
}

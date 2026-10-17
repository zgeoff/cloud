// Checks the agent image (images/agent) from inside a running copy of it: each pinned tool answers
// with the version the Dockerfile pins, no login state or credential file exists, and gitleaks finds
// no secret on the filesystem. scripts/agent-image-check-guest.sh holds the checks.
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { buildAgentImageGuestScript } from './build-agent-image-guest-script.ts';
import { createAgentImageCheckDir } from './create-agent-image-check-dir.ts';
import { ExitError } from './exit-error.ts';
import { buildImpArgv } from './imp-cli.ts';
import { loadAgentImagePins } from './load-agent-image-pins.ts';
import { runOrExit } from './run-or-exit.ts';
import type { InterruptibleIO } from './subscribe-to-interrupts.ts';
import { subscribeToInterrupts } from './subscribe-to-interrupts.ts';
import { withExitCode } from './with-exit-code.ts';
import { withWorkDir } from './with-work-dir.ts';

export interface CheckAgentImageOptions extends InterruptibleIO {
  // `--imp <name>` for a fresh imp from the image, or `--docker <image>` for a local build
  readonly args: readonly string[];

  // the zgeoff/cloud checkout whose Dockerfile, gitleaks config and checks it uses
  readonly repo: string;
}

// Prints one line per check and returns the guest's exit code: 1 when any check fails
export function checkAgentImage(options: Readonly<CheckAgentImageOptions>): Promise<number> {
  return withExitCode(options.printErr, () => {
    const target = parseTarget(options.args);

    return withWorkDir(options, 'agent-image-check-', (work) => runCheck(options, target, work));
  });
}

interface Target {
  readonly mode: 'imp' | 'docker';
  readonly name: string;
}

function parseTarget(args: readonly string[]): Target {
  const [flag, name = ''] = args;

  if (args.length !== 2 || (flag !== '--imp' && flag !== '--docker') || name === '') {
    throw new ExitError(2, 'usage: check-agent-image.ts --imp <name> | --docker <image>');
  }

  return { mode: flag === '--imp' ? 'imp' : 'docker', name };
}

// gitleaks sweeps the whole image, so the guest gets longer than a call's default
const guestTimeoutMs = 900_000;

async function runCheck(options: Readonly<CheckAgentImageOptions>, target: Target, work: string) {
  const pins = await loadAgentImagePins(join(options.repo, 'images/agent/Dockerfile'));
  const dir = await createAgentImageCheckDir(options, { work, repo: options.repo, pins });
  const body = await readFile(join(options.repo, 'scripts/agent-image-check-guest.sh'), 'utf8');

  const stdin = Buffer.from(buildAgentImageGuestScript({ pins, mode: target.mode, body }));

  const argv = await setupGuest(options, target, dir);
  const result = await options.run(argv, { stdin, timeoutMs: guestTimeoutMs });

  options.printOut(result.stdout.toString());
  options.printErr(result.stderr.toString());

  return result.exitCode;
}

// An imp gets the check directory copied to its /run, a tmpfs there; docker mounts it read-only.
// Returns the command that runs bash in the image with the guest script on stdin.
async function setupGuest(options: Readonly<CheckAgentImageOptions>, target: Target, dir: string) {
  if (target.mode === 'docker') {
    const mount = `${dir}:/run/agent-image-check:ro`;

    return ['docker', 'run', '--rm', '-i', '-v', mount, target.name, 'bash', '-s'];
  }

  await runOrExit(options, buildImpArgv(['cp', dir, `${target.name}:/run/agent-image-check`]));

  return buildImpArgv(['exec', target.name, '--', 'bash', '-s']);
}

if (import.meta.main) {
  const trap = subscribeToInterrupts();

  process.exitCode = await checkAgentImage({
    ...trap,
    args: process.argv.slice(2),
    repo: join(import.meta.dir, '..'),
  });

  trap.unsubscribe();
}

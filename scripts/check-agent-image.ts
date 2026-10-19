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
  readonly args: readonly string[];

  readonly repo: string;
}

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
  const directory = await createAgentImageCheckDir(options, { work, repo: options.repo, pins });
  const body = await readFile(join(options.repo, 'scripts/agent-image-check-guest.sh'), 'utf8');

  const stdin = Buffer.from(buildAgentImageGuestScript({ pins, mode: target.mode, body }));

  const argv = await setupGuest(options, target, directory);
  const result = await options.run(argv, { stdin, timeoutMs: guestTimeoutMs });

  options.printOut(result.stdout.toString());
  options.printErr(result.stderr.toString());

  return result.exitCode;
}

async function setupGuest(
  options: Readonly<CheckAgentImageOptions>,
  target: Target,
  directory: string,
) {
  if (target.mode === 'docker') {
    const mount = `${directory}:/run/agent-image-check:ro`;

    return ['docker', 'run', '--rm', '-i', '-v', mount, target.name, 'bash', '-s'];
  }

  await runOrExit(
    options,
    buildImpArgv(['cp', directory, `${target.name}:/run/agent-image-check`]),
  );

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

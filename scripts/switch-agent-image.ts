// Points the atc daemon's cloud target at a checked agent image. Run it on the machine that runs the
// daemon, once build-agent-image.ts printed "check passed" for the image, as
// `bun scripts/switch-agent-image.ts <image> [<atc config file>]`.
import { homedir } from 'node:os';
import { join } from 'node:path';
import { ExitError } from './exit-error.ts';
import { findRecord } from './find-record.ts';
import { loadCloudTarget } from './load-cloud-target.ts';
import { parseJSONOutput } from './parse-json-output.ts';
import type { ScriptIO } from './run-or-exit.ts';
import { runOrExit } from './run-or-exit.ts';
import { runProcess } from './run-process.ts';
import { withExitCode } from './with-exit-code.ts';
import { writeCloudTargetImage } from './write-cloud-target-image.ts';

export interface SwitchAgentImageOptions extends ScriptIO {
  readonly args: readonly string[];

  // the home whose .config/atc/config.json is the default config
  readonly home: string;

  // the time in milliseconds since the epoch, as Date.now returns it
  readonly now: () => number;
}

// the atc that the agent image installs, which the daemon runs in the guest
const guestATC = '/usr/local/bin/atc';

// It never restarts the daemon, which reads its targets at startup: it prints the restart command
// for a person to run when no session needs the daemon.
export function switchAgentImage(options: Readonly<SwitchAgentImageOptions>): Promise<number> {
  return withExitCode(options.printErr, async () => {
    const [image, config] = parseArgs(options.args, options.home);

    const target = await loadCloudTarget(config);

    if (target.image === image && target.guestATC === guestATC) {
      options.printOut(`the cloud target already runs ${image}\n`);

      return 0;
    }

    await requireImpImage(options, image);

    const backup = await writeCloudTargetImage({ config, image, guestATC, now: options.now() });

    options.printOut(
      `backed up ${config} to ${backup}\n` +
        `set targets.cloud.image to ${image} (was ${target.image ?? 'unset'})\n` +
        'the daemon reads its targets at startup: restart it when no session needs it, with\n' +
        '  atc daemon restart\n',
    );

    return 0;
  });
}

function parseArgs(args: readonly string[], home: string): readonly [string, string] {
  const [image = '', config = join(home, '.config/atc/config.json')] = args;

  if (args.length > 2 || image === '') {
    throw new ExitError(2, 'usage: switch-agent-image.ts <image> [<atc config file>]');
  }

  return [image, config];
}

async function requireImpImage(io: Readonly<ScriptIO>, image: string) {
  const result = await runOrExit(io, ['impz', 'image', 'ls', '--json']);

  const images = parseJSONOutput(result.stdout.toString(), 'impz image ls');

  if (findRecord(images, 'name', image) === undefined) {
    throw new ExitError(
      1,
      `the imp host has no image ${image}: build it with scripts/build-agent-image.ts first`,
    );
  }
}

if (import.meta.main) {
  process.exitCode = await switchAgentImage({
    args: process.argv.slice(2),
    home: homedir(),
    now: () => Date.now(),
    run: runProcess,
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}

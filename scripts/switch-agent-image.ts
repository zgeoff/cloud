// Run it on the machine that runs the atc daemon, once the agent image build printed "check
// passed" for the image.
import { copyFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import type { Clock } from '@zgeoff/std';
import { systemClock } from '@zgeoff/std';
import { recordAgentImageRetention } from './agent-image-retention-state.ts';
import { ExitError } from './exit-error.ts';
import { findJSONField } from './find-json-field.ts';
import { findRecord } from './find-record.ts';
import { buildImpArgv, loadImpJSON } from './imp-cli.ts';
import { loadCloudTarget } from './load-cloud-target.ts';
import type { ScriptIO } from './run-or-exit.ts';
import { runOrExit } from './run-or-exit.ts';
import { runProcess } from './run-process.ts';
import { withExitCode } from './with-exit-code.ts';
import { writeCloudTargetImage } from './write-cloud-target-image.ts';

export interface SwitchAgentImageOptions extends ScriptIO, Pick<Clock, 'now'> {
  readonly args: readonly string[];

  readonly home: string;

  // the folder that a relative config path starts from
  readonly cwd: string;
}

const guestATC = '/usr/local/bin/atc';

export function switchAgentImage(options: Readonly<SwitchAgentImageOptions>): Promise<number> {
  return withExitCode(options.printErr, async () => {
    const [image, config] = parseArgs(options.args, options.home, options.cwd);

    const target = await loadCloudTarget(config);
    const record = await requireImpImage(options, image);

    // A build on this machine reads the target from this file, and treats an image that no passing
    // check pinned as a switch-only one. Both go on record before the pin.
    await recordAgentImageRetention(options.home, {
      config,
      ...(findJSONField(record, 'pinned') === true ? {} : { switchOnlyImage: image }),
    });

    // impd never evicts a pinned image, and the daemon boots this one by name. A config that
    // already names the image gets the pin too, since a refused or lost pin leaves it evictable.
    await runOrExit(options, buildImpArgv(['image', 'pin', image]));

    if (target.image === image && target.guestATC === guestATC) {
      options.printOut(`the cloud target already runs ${image}\n`);

      return 0;
    }

    const backup = await writeCloudTargetImage({ config, image, guestATC, now: options.now() });

    // an agent image build that read the targets before this write may unpin the image after the
    // first pin, so the pin repeats once the config names the image
    try {
      await runOrExit(options, buildImpArgv(['image', 'pin', image]));
    } catch (error) {
      // a refused pin leaves the image evictable, so the target keeps the image it ran
      await copyFile(backup, config);

      throw error;
    }

    options.printOut(
      `backed up ${config} to ${backup}\n` +
        `set targets.cloud.image to ${image} (was ${target.image ?? 'unset'})\n` +
        'the daemon reads its targets at startup: restart it when no session needs it, with\n' +
        '  atc daemon restart\n',
    );

    return 0;
  });
}

function parseArgs(args: readonly string[], home: string, cwd: string): readonly [string, string] {
  const [image = '', config = join(home, '.config/atc/config.json')] = args;

  if (args.length > 2 || image === '') {
    throw new ExitError(2, 'usage: switch-agent-image.ts <image> [<atc config file>]');
  }

  // retention reads the recorded path from any folder, so it is recorded as an absolute one
  return [image, resolve(cwd, config)];
}

async function requireImpImage(io: Readonly<ScriptIO>, image: string): Promise<unknown> {
  const images = await loadImpJSON(io, ['image', 'ls']);

  const record = findRecord(images, 'name', image);

  if (record === undefined) {
    throw new ExitError(
      1,
      `the imp host has no image ${image}: build it with scripts/build-agent-image.ts first`,
    );
  }

  return record;
}

if (import.meta.main) {
  process.exitCode = await switchAgentImage({
    args: process.argv.slice(2),
    home: homedir(),
    cwd: process.cwd(),
    now: systemClock.now,
    run: runProcess,
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}

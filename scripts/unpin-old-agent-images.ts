import { readAgentImageRetentionState } from './agent-image-retention-state.ts';
import { ExitError } from './exit-error.ts';
import { buildImpArgv, loadImpJSON } from './imp-cli.ts';
import { pickAgentImagesToUnpin } from './pick-agent-images-to-unpin.ts';
import { pullDeployedHostTag } from './pull-deployed-host-tag.ts';
import { readTargetAgentImages } from './read-target-agent-images.ts';
import type { ScriptIO } from './run-or-exit.ts';
import type { TargetImageFiles } from './types.ts';

export interface AgentImageRetention {
  readonly newImage: string;
  readonly targetFiles: Readonly<TargetImageFiles>;

  // the home folder that holds what switch-agent-image recorded
  readonly home: string | undefined;
}

// Lets impd's eviction remove the agent images that nothing needs. It never deletes an image, and a
// failure is logged and leaves the build's result alone. It unpins none when it cannot tell which
// images the targets boot, and exits 1 when a target's image stays unpinned.
export async function unpinOldAgentImages(
  io: Readonly<ScriptIO>,
  retention: Readonly<AgentImageRetention>,
): Promise<void> {
  let stale: readonly string[];

  try {
    await pullDeployedHostTag(io, retention.targetFiles.nix.clone);

    const images = await loadImpJSON(io, ['image', 'ls']);
    const targets = await readTargets(io, retention);

    stale = pickAgentImagesToUnpin({
      images,
      newImage: retention.newImage,
      targetImages: targets.images,
      switchOnlyImages: targets.switchOnlyImages,
    });
  } catch (error) {
    io.printErr(`kept every agent image pinned: ${describe(error)}\n`);

    return;
  }

  const stranded: string[] = [];

  for (const image of stale) {
    // one image's failure leaves the others to unpin
    // oxlint-disable-next-line no-await-in-loop
    if ((await unpinImage(io, retention, image)) === 'stranded') {
      stranded.push(image);
    }
  }

  if (stranded.length > 0) {
    throw new ExitError(
      1,
      `a target boots ${stranded.join(', ')} but impd refused to pin it again, so impd may evict ` +
        'it: pin it with impz image pin <image>',
    );
  }
}

interface TargetReads {
  readonly images: readonly string[];
  readonly switchOnlyImages: readonly string[];
}

async function readTargets(
  io: Readonly<ScriptIO>,
  retention: Readonly<AgentImageRetention>,
): Promise<TargetReads> {
  const state =
    retention.home === undefined
      ? { configs: [], switchOnlyImages: [] }
      : await readAgentImageRetentionState(retention.home);

  const images = await readTargetAgentImages(io, {
    ...retention.targetFiles,
    atcConfigs: [...retention.targetFiles.atcConfigs, ...state.configs],
  });

  return { images, switchOnlyImages: state.switchOnlyImages };
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

type UnpinOutcome = 'done' | 'stranded';

async function unpinImage(
  io: Readonly<ScriptIO>,
  retention: Readonly<AgentImageRetention>,
  image: string,
): Promise<UnpinOutcome> {
  try {
    // A switch can name the image after the list was read, so the targets are read again before the
    // unpin and after it. A switch that writes its config after the second read pins the image
    // again itself.
    const bootedBefore = await readTargetBoots(io, retention, image);

    if (bootedBefore) {
      io.printErr(`kept ${image} pinned: a target boots it now\n`);

      return 'done';
    }

    const result = await io.run(buildImpArgv(['image', 'unpin', image]));

    if (result.exitCode !== 0 || result.timedOut) {
      io.printErr(`could not unpin ${image}: ${result.stderr.toString().trim()}\n`);

      return 'done';
    }

    io.printErr(`unpinned ${image}; impd may evict it when it frees disk\n`);

    const bootedAfter = await readTargetBoots(io, retention, image);

    return bootedAfter ? await repairPin(io, image) : 'done';
  } catch (error) {
    io.printErr(`could not unpin ${image}: ${describe(error)}\n`);

    return 'done';
  }
}

async function readTargetBoots(
  io: Readonly<ScriptIO>,
  retention: Readonly<AgentImageRetention>,
  image: string,
): Promise<boolean> {
  const targets = await readTargets(io, retention);

  return targets.images.includes(image);
}

// how often the pin that repairs an overtaken unpin is tried
const repairAttempts = 3;

async function repairPin(io: Readonly<ScriptIO>, image: string): Promise<UnpinOutcome> {
  let lastError = '';

  for (let attempt = 1; attempt <= repairAttempts; attempt += 1) {
    // a refused pin is tried again before the image is given up as unpinned
    // oxlint-disable-next-line no-await-in-loop
    const repin = await io.run(buildImpArgv(['image', 'pin', image]));

    if (repin.exitCode === 0 && !repin.timedOut) {
      io.printErr(`pinned ${image} again: a target boots it now\n`);

      return 'done';
    }

    lastError = repin.stderr.toString().trim();
  }

  io.printErr(
    `could not pin ${image} again although a target boots it now, so impd may evict it: ` +
      `pin it with impz image pin ${image}: ${lastError}\n`,
  );

  return 'stranded';
}

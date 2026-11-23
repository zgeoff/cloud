import { loadAgentImageRetentionState } from './agent-image-retention-state.ts';
import { buildImpArgv, loadImpJSON } from './imp-cli.ts';
import type { TargetImageFiles } from './load-target-agent-images.ts';
import { loadTargetAgentImages, pullDeployedHostTag } from './load-target-agent-images.ts';
import type { ScriptIO } from './run-or-exit.ts';
import { selectAgentImagesToUnpin } from './select-agent-images-to-unpin.ts';

export interface AgentImageRetention {
  readonly newImage: string;
  readonly targetFiles: Readonly<TargetImageFiles>;

  // the home folder that holds what switch-agent-image recorded
  readonly home: string | undefined;
}

// Lets impd's eviction remove the agent images that nothing needs. It never deletes an image, and
// a failure here is logged and leaves the build's result alone. When it cannot tell which images
// the targets boot, it unpins none.
export async function unpinOldAgentImages(
  io: Readonly<ScriptIO>,
  retention: Readonly<AgentImageRetention>,
): Promise<void> {
  let stale: readonly string[];

  try {
    await pullDeployedHostTag(io, retention.targetFiles.nix.clone);

    const images = await loadImpJSON(io, ['image', 'ls']);
    const targets = await readTargets(io, retention);

    stale = selectAgentImagesToUnpin({
      images,
      newImage: retention.newImage,
      targetImages: targets.images,
      switchOnlyImages: targets.switchOnlyImages,
    });
  } catch (error) {
    io.printErr(`kept every agent image pinned: ${describe(error)}\n`);

    return;
  }

  for (const image of stale) {
    // one image's failure leaves the others to unpin
    // oxlint-disable-next-line no-await-in-loop
    await unpinImage(io, retention, image);
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
      : await loadAgentImageRetentionState(retention.home);

  const images = await loadTargetAgentImages(io, {
    ...retention.targetFiles,
    atcConfigs: [...retention.targetFiles.atcConfigs, ...state.configs],
  });

  return { images, switchOnlyImages: state.switchOnlyImages };
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

async function unpinImage(
  io: Readonly<ScriptIO>,
  retention: Readonly<AgentImageRetention>,
  image: string,
) {
  try {
    // A switch can name the image after the list was read, so the targets are read again before the
    // unpin and after it. A switch that writes its config after the second read pins the image
    // again itself.
    const bootedBefore = await readTargetBoots(io, retention, image);

    if (bootedBefore) {
      io.printErr(`kept ${image} pinned: a target boots it now\n`);

      return;
    }

    const result = await io.run(buildImpArgv(['image', 'unpin', image]));

    if (result.exitCode !== 0 || result.timedOut) {
      io.printErr(`could not unpin ${image}: ${result.stderr.toString().trim()}\n`);

      return;
    }

    io.printErr(`unpinned ${image}; impd may evict it when it frees disk\n`);

    const bootedAfter = await readTargetBoots(io, retention, image);

    if (bootedAfter) {
      const repin = await io.run(buildImpArgv(['image', 'pin', image]));

      if (repin.exitCode !== 0 || repin.timedOut) {
        io.printErr(
          `could not pin ${image} again although a target boots it now, so impd may evict it: ` +
            `pin it with impz image pin ${image}: ${repin.stderr.toString().trim()}\n`,
        );

        return;
      }

      io.printErr(`pinned ${image} again: a target boots it now\n`);
    }
  } catch (error) {
    io.printErr(`could not unpin ${image}: ${describe(error)}\n`);
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

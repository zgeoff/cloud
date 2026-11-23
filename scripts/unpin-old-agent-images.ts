import { buildImpArgv, loadImpJSON } from './imp-cli.ts';
import type { TargetImageFiles } from './load-target-agent-images.ts';
import { loadTargetAgentImages } from './load-target-agent-images.ts';
import type { ScriptIO } from './run-or-exit.ts';
import { selectAgentImagesToUnpin } from './select-agent-images-to-unpin.ts';

export interface AgentImageRetention {
  readonly newImage: string;
  readonly targetFiles: Readonly<TargetImageFiles>;
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
    const images = await loadImpJSON(io, ['image', 'ls']);
    const targetImages = await loadTargetAgentImages(io, retention.targetFiles);

    stale = selectAgentImagesToUnpin({ images, newImage: retention.newImage, targetImages });
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
      await io.run(buildImpArgv(['image', 'pin', image]));

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
  const targetImages = await loadTargetAgentImages(io, retention.targetFiles);

  return targetImages.includes(image);
}

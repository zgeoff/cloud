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
// a failure here is logged and leaves the build's result alone.
export async function unpinOldAgentImages(
  io: Readonly<ScriptIO>,
  retention: Readonly<AgentImageRetention>,
): Promise<void> {
  try {
    const images = await loadImpJSON(io, ['image', 'ls']);
    const targetImages = await loadTargetAgentImages(retention.targetFiles);

    const stale = selectAgentImagesToUnpin({ images, newImage: retention.newImage, targetImages });

    for (const image of stale) {
      // one image's failure leaves the others to unpin
      // oxlint-disable-next-line no-await-in-loop
      await unpinImage(io, image);
    }
  } catch (error) {
    io.printErr(`could not list the agent images to unpin: ${describe(error)}\n`);
  }
}

async function unpinImage(io: Readonly<ScriptIO>, image: string) {
  const result = await io.run(buildImpArgv(['image', 'unpin', image]));

  if (result.exitCode === 0 && !result.timedOut) {
    io.printErr(`unpinned ${image}; impd may evict it when it frees disk\n`);

    return;
  }

  io.printErr(`could not unpin ${image}: ${result.stderr.toString().trim()}\n`);
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

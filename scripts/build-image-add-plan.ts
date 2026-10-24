import type { SandboxImage } from './parse-nixie-sandbox-manifest.ts';

export interface HeldImage {
  readonly name: string;
  readonly ref: string;
  readonly digest: string;
}

export interface ImageAddPlan {
  readonly adds: readonly SandboxImage[];
  readonly held: readonly string[];
  readonly conflicts: readonly string[];
}

// nixie counts an image as added when impd holds its name at the manifest's digest, either as the
// image's own digest or as the digest that the held ref pins, so this plan agrees with nixie's start
export function buildImageAddPlan(
  wanted: readonly SandboxImage[],
  heldImages: readonly HeldImage[],
): ImageAddPlan {
  const byName = new Map(heldImages.map((image) => [image.name, image]));

  const adds: SandboxImage[] = [];
  const held: string[] = [];
  const conflicts: string[] = [];

  for (const image of wanted) {
    const found = byName.get(image.name);

    if (found === undefined) {
      adds.push(image);
    } else if (found.digest === image.digest || found.ref.endsWith(`@${image.digest}`)) {
      held.push(image.name);
    } else {
      conflicts.push(
        `impd holds the image ${image.name} at ${found.digest} from ${found.ref}, not ${image.digest}`,
      );
    }
  }

  return { adds, held, conflicts };
}

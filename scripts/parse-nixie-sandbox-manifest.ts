import { z } from 'zod';

export interface SandboxImage {
  readonly name: string;
  readonly ref: string;
  readonly digest: string;
}

export type SandboxManifest =
  | { readonly ok: true; readonly images: readonly SandboxImage[] }
  | { readonly ok: false; readonly error: string };

// nixie's impd token adds images only from refs under this path, pinned by digest, and under names
// with nixie's prefix
const refPattern = /^ghcr\.io\/zgeoff\/nixie-[a-z0-9-]+@(?<digest>sha256:[0-9a-f]{64})$/u;

const imageSchema = z
  .strictObject({
    name: z.string().regex(/^nixie-[a-z0-9-]+$/u),
    ref: z.string().regex(refPattern),
  })
  .transform((image) => ({
    ...image,
    digest: image.ref.slice(image.ref.lastIndexOf('@') + 1),
  }));

const manifestSchema = z.record(z.string(), imageSchema);

// the output of `nixie sandbox-manifest`: each sandbox kind with the name and ref of its image
export function parseNixieSandboxManifest(text: string): SandboxManifest {
  const json = parseJSON(text);

  if (json === undefined) {
    return { ok: false, error: 'nixie printed a sandbox manifest that is not JSON' };
  }

  const result = manifestSchema.safeParse(json);

  if (!result.success) {
    return { ok: false, error: `nixie's sandbox manifest: ${z.prettifyError(result.error)}` };
  }

  const images = Object.values(result.data);

  return images.length === 0
    ? { ok: false, error: "nixie's sandbox manifest lists no image" }
    : { ok: true, images };
}

function parseJSON(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

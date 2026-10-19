// A stand-in for the service's writeBytes on a volume that fills during the write: it writes the
// file's first byte to path, as a real write does before the volume runs out, then fails with the
// real ENOSPC that a write to /dev/full raises.
export function buildStubFullVolumeWrite(): (path: string, file: Blob) => Promise<unknown> {
  return async (path, file) => {
    const bytes = await file.arrayBuffer();

    await Bun.write(path, new Uint8Array(bytes, 0, 1));

    return Bun.write('/dev/full', file);
  };
}

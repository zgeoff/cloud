// a real write to a volume that fills puts its first bytes down before it fails, and a write to
// /dev/full raises the real ENOSPC
export function buildStubFullVolumeWrite(): (path: string, file: Blob) => Promise<unknown> {
  return writeToFullVolume;
}

async function writeToFullVolume(path: string, file: Blob): Promise<unknown> {
  const bytes = await file.arrayBuffer();

  await Bun.write(path, new Uint8Array(bytes, 0, 1));

  return Bun.write('/dev/full', file);
}

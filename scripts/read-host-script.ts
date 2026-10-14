import { readFile } from 'node:fs/promises';

// Reads one of the bash scripts in scripts/host/, which a caller sends on ssh's stdin to run
// there as `bash -s`, so the script's text never reaches the host's command line
export async function readHostScript(name: string): Promise<Buffer> {
  const text = await readFile(new URL(`host/${name}`, import.meta.url));

  return Buffer.from(text);
}

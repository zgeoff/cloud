import { readFile } from 'node:fs/promises';

export async function readHostScript(name: string): Promise<Buffer> {
  const text = await readFile(new URL(`host/${name}`, import.meta.url));

  return Buffer.from(text);
}

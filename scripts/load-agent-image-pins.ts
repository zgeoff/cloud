import { readFile } from 'node:fs/promises';

export async function loadAgentImagePins(
  dockerfile: string,
): Promise<Readonly<Record<string, string>>> {
  const text = await readFile(dockerfile, 'utf8');

  const pins: Record<string, string> = {};

  for (const match of text.matchAll(/^ARG (?<name>[A-Z0-9_]+)=(?<value>.*)$/gmu)) {
    pins[match.groups?.['name'] ?? ''] = match.groups?.['value'] ?? '';
  }

  return pins;
}

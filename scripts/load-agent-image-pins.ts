import { readFile } from 'node:fs/promises';

// Reads every `ARG <NAME>=<value>` pin of a Dockerfile, by name, in the file's order
export async function loadAgentImagePins(dockerfile: string): Promise<ReadonlyMap<string, string>> {
  const text = await readFile(dockerfile, 'utf8');

  const pins = text
    .split('\n')
    .map((line) => /^ARG (?<name>[A-Z0-9_]+)=(?<value>.*)$/u.exec(line)?.groups)
    .filter((groups) => groups !== undefined)
    .map((groups): [string, string] => [groups['name'] ?? '', groups['value'] ?? '']);

  return new Map(pins);
}

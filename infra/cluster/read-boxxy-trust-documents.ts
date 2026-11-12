import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

// The trust documents in a folder, by file name: each `*.json` file is one issuer's document, as
// `impz identity jwks` prints it. A missing folder holds none.
export function readBoxxyTrustDocuments(folder: string): Readonly<Record<string, string>> {
  const names = readJSONFileNames(folder);

  return Object.fromEntries(
    names.map((name) => [name, readFileSync(join(folder, name), 'utf8')] as const),
  );
}

function readJSONFileNames(folder: string): readonly string[] {
  try {
    return readdirSync(folder, { withFileTypes: true })
      .filter((entry) => entry.isFile() && entry.name.endsWith('.json'))
      .map((entry) => entry.name)
      .toSorted((left, right) => left.localeCompare(right));
  } catch {
    return [];
  }
}

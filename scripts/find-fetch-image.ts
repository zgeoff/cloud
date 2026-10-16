import { findJSONField } from './find-json-field.ts';

// Finds the name impd holds nixie's fetch image under, from what nixie sandbox-manifest prints: each
// sandbox kind with its image's ref and the name nixie gives the image in impd
export function findFetchImage(manifestText: string): string | undefined {
  try {
    const manifest: unknown = JSON.parse(manifestText);
    const name = findJSONField(findJSONField(manifest, 'fetch'), 'name');

    return typeof name === 'string' && /^nixie-fetch-[\da-f]{12}$/u.test(name) ? name : undefined;
  } catch {
    return undefined;
  }
}

import { findJSONField } from './find-json-field.ts';

export function findFetchImage(manifestText: string): string | undefined {
  try {
    const manifest: unknown = JSON.parse(manifestText);
    const name = findJSONField(findJSONField(manifest, 'fetch'), 'name');

    return typeof name === 'string' && /^nixie-fetch-[\da-f]{12}$/u.test(name) ? name : undefined;
  } catch {
    return undefined;
  }
}

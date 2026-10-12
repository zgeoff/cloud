import { findJSONField } from './find-json-field.ts';

// Finds the name impd holds nixie's fetch image under, from nixie's sandbox manifest: nixie names
// each sandbox image nixie-<kind>-<first 12 hex of the digest>
export function findFetchImage(manifestText: string): string | undefined {
  const ref = findFetchRef(manifestText);
  const digest = /@sha256:(?<hex>[\da-f]{64})$/u.exec(ref ?? '')?.groups?.['hex'];

  return digest === undefined ? undefined : `nixie-fetch-${digest.slice(0, 12)}`;
}

function findFetchRef(text: string): string | undefined {
  try {
    const manifest: unknown = JSON.parse(text);
    const ref = findJSONField(manifest, 'fetch');

    return typeof ref === 'string' ? ref : undefined;
  } catch {
    return undefined;
  }
}

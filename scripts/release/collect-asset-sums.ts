import { findJSONField } from '../find-json-field.ts';

// GitHub lists a release asset's digest as `sha256:` and 64 hex digits
const digestPattern = /^sha256:(?<sum>[0-9a-f]{64})$/iu;

// an asset with no sha256 digest stays out, so a pin that needs its sum fails the bump
export function collectAssetSums(assets: unknown): Record<string, string> {
  const sums: Record<string, string> = {};
  const list: readonly unknown[] = Array.isArray(assets) ? assets : [];

  for (const asset of list) {
    const name = findJSONField(asset, 'name');
    const digest = findJSONField(asset, 'digest');

    const sum =
      typeof digest === 'string' ? digestPattern.exec(digest)?.groups?.['sum'] : undefined;

    if (typeof name === 'string' && sum !== undefined) {
      sums[name] = sum.toLowerCase();
    }
  }

  return sums;
}

import { createHash } from 'node:crypto';

export function buildSecretChecksum(data: Readonly<Record<string, string>>): string {
  const entries = Object.entries(data).toSorted(([left], [right]) => left.localeCompare(right));

  return createHash('sha256').update(JSON.stringify(entries)).digest('hex');
}

import type { ReleaseRecord } from './release-registry.ts';
import { releaseRegistry } from './release-registry.ts';

export function findReleaseRecord(branch: string): ReleaseRecord | undefined {
  return releaseRegistry.find((record) => `release-check/${record.name}` === branch);
}

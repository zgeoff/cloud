import type { ReleaseRecord } from './release-registry.ts';
import { releaseRegistry } from './release-registry.ts';

// the record whose bump pull request opens from the branch, release-check/<name>, or undefined
// for any other branch
export function findReleaseRecord(branch: string): ReleaseRecord | undefined {
  return releaseRegistry.find((record) => `release-check/${record.name}` === branch);
}

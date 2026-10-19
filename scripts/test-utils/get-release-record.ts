import type { ReleaseRecord } from '../release/release-registry.ts';
import { releaseRegistry } from '../release/release-registry.ts';

export function getReleaseRecord(name: string): ReleaseRecord {
  const record = releaseRegistry.find((each) => each.name === name);

  if (record === undefined) {
    throw new Error(`the release registry has no ${name} record`);
  }

  return record;
}

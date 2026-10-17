import type { ReleaseRecord } from '../release/release-registry.ts';
import { releaseRegistry } from '../release/release-registry.ts';

// the registry's record of that name, for a test that runs a dependency's real pins; a name the
// registry lacks throws, so a test never runs without its record
export function getReleaseRecord(name: string): ReleaseRecord {
  const record = releaseRegistry.find((each) => each.name === name);

  if (record === undefined) {
    throw new Error(`the release registry has no ${name} record`);
  }

  return record;
}

import type { ReleaseRead, ReleaseReadResult } from './read-release-values.ts';

// a lockfile install pins only the version: the lock step resolves the package and records each
// sha512, so the release gives no value to read, and this read only waits for npm to list it
export async function readNPMPackageValues(
  read: ReleaseRead,
  packageName: string,
): Promise<ReleaseReadResult | Error> {
  const url = `https://registry.npmjs.org/${packageName}/${read.version}`;

  const response = await fetch(url);

  // the GitHub release comes first, so a version npm lacks yet fails this run, and the next one
  // pins it
  return response.ok
    ? { values: {}, flags: [] }
    : new Error(`the npm registry answered ${response.status} for ${url}`);
}

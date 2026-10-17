import type { ReleaseVersion } from './parse-release-version.ts';

// true when candidate is a later release than base, comparing major, then minor, then patch as
// numbers, as `sort -V` orders X.Y.Z
export function isNewerVersion(candidate: ReleaseVersion, base: ReleaseVersion): boolean {
  if (candidate.major !== base.major) {
    return candidate.major > base.major;
  }

  if (candidate.minor !== base.minor) {
    return candidate.minor > base.minor;
  }

  return candidate.patch > base.patch;
}

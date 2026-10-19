import type { ReleaseVersion } from './parse-release-version.ts';

export function isNewerVersion(candidate: ReleaseVersion, base: ReleaseVersion): boolean {
  if (candidate.major !== base.major) {
    return candidate.major > base.major;
  }

  if (candidate.minor !== base.minor) {
    return candidate.minor > base.minor;
  }

  return candidate.patch > base.patch;
}

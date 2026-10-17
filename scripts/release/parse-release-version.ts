// A release version is X.Y.Z, each part a decimal number, as every dependency the release check
// pins tags its releases
export interface ReleaseVersion {
  readonly major: number;
  readonly minor: number;
  readonly patch: number;
}

// parses X.Y.Z, and gives undefined for any other text, a v prefix or a prerelease among it
export function parseReleaseVersion(text: string): ReleaseVersion | undefined {
  const groups = /^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$/u.exec(text)?.groups;

  if (groups === undefined) {
    return undefined;
  }

  return {
    major: Number(groups['major']),
    minor: Number(groups['minor']),
    patch: Number(groups['patch']),
  };
}

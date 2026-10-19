export interface ReleaseVersion {
  readonly major: number;
  readonly minor: number;
  readonly patch: number;
}

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

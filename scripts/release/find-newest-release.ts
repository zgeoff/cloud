import { isNewerVersion } from './is-newer-version.ts';
import { parseReleaseVersion } from './parse-release-version.ts';

export function findNewestRelease(tags: readonly string[], prefix: string): string | undefined {
  const versions = tags
    .filter((tag) => tag.startsWith(prefix))
    .map((tag) => tag.slice(prefix.length))
    .filter((each) => parseReleaseVersion(each) !== undefined);

  return versions.reduce<string | undefined>((newest, each) => {
    const candidate = parseReleaseVersion(each);
    const best = newest === undefined ? undefined : parseReleaseVersion(newest);

    return candidate !== undefined && (best === undefined || isNewerVersion(candidate, best))
      ? each
      : newest;
  }, undefined);
}

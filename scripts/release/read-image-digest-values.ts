import { readImageDigest } from './read-image-digest.ts';
import type { ReleaseRead, ReleaseReadResult } from './read-release-values.ts';
import { runChecked } from './run-checked.ts';

// Reads the tag's commit from GitHub, and the digest that each image's version tag names on
// GHCR, as `docker buildx imagetools inspect` prints the manifest descriptor
export async function readImageDigestValues(
  read: ReleaseRead,
  images: readonly string[],
): Promise<ReleaseReadResult | Error> {
  const tag = `${read.record.tagPrefix}${read.version}`;

  const commit = await runChecked(read.run, [
    'gh',
    'api',
    `repos/${read.record.repo}/commits/${tag}`,
    '--jq',
    '.sha',
  ]);

  if (commit instanceof Error || !/^[0-9a-f]{40}$/u.test(commit.trim())) {
    return commit instanceof Error ? commit : new Error(`not a commit: '${commit.trim()}'`);
  }

  const digests = await readDigests(read, images);

  return digests instanceof Error
    ? digests
    : { values: { commit: commit.trim(), digests }, flags: [] };
}

async function readDigests(read: ReleaseRead, images: readonly string[]) {
  const digests: Record<string, string> = {};

  for (const image of images) {
    const digest = await readImageDigest(read.run, `ghcr.io/zgeoff/${image}:${read.version}`);

    if (digest instanceof Error) {
      return digest;
    }

    digests[image] = digest;
  }

  return digests;
}

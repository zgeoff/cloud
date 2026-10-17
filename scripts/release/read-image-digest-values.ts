import { findJSONField } from '../find-json-field.ts';
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
    const digest = await readDigest(read, image);

    if (digest instanceof Error) {
      return digest;
    }

    digests[image] = digest;
  }

  return digests;
}

async function readDigest(read: ReleaseRead, image: string) {
  const manifest = await runChecked(read.run, [
    'docker',
    'buildx',
    'imagetools',
    'inspect',
    `ghcr.io/zgeoff/${image}:${read.version}`,
    '--format',
    '{{json .Manifest}}',
  ]);

  if (manifest instanceof Error) {
    return manifest;
  }

  const digest = findJSONField(tryParseJSON(manifest), 'digest');

  return typeof digest === 'string' && /^sha256:[0-9a-f]{64}$/u.test(digest)
    ? digest
    : new Error(`ghcr.io/zgeoff/${image}:${read.version} names no sha256 digest`);
}

function tryParseJSON(text: string): unknown {
  try {
    const value: unknown = JSON.parse(text);

    return value;
  } catch {
    return null;
  }
}

import { readFileSync } from 'node:fs';

const imagePattern = /^GIT_SYNC_IMAGE=(?<image>\S+@sha256:[\da-f]{64})$/mu;

// The git-sync image that images/boxxy/versions.env pins, by tag and digest: the boxxy server's
// rules sidecar runs it, and the image test writes its checkout with it.
export function readGitSyncImage(): string {
  return parseGitSyncImage(
    readFileSync(new URL('../../images/boxxy/versions.env', import.meta.url), 'utf8'),
  );
}

export function parseGitSyncImage(text: string): string {
  const image = imagePattern.exec(text)?.groups?.['image'];

  if (image === undefined) {
    throw new Error(
      'images/boxxy/versions.env has no GIT_SYNC_IMAGE line of the form <image>:<tag>@sha256:<digest>',
    );
  }

  return image;
}

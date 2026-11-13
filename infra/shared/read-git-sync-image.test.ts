import { expect, test } from 'bun:test';
import { parseGitSyncImage, readGitSyncImage } from './read-git-sync-image.ts';

// a git-sync pin, by tag and digest
function setupTest(): string {
  return 'registry.k8s.io/git-sync/git-sync:v4.8.0@sha256:1111111111111111111111111111111111111111111111111111111111111111';
}

test('#parseGitSyncImage reads the GIT_SYNC_IMAGE line among the other pins', () => {
  const image = setupTest();

  expect(
    parseGitSyncImage(
      [
        '# Pins for the boxxy image.',
        'BOXXY_BASE_IMAGE=example.invalid/base:latest@sha256:2222222222222222222222222222222222222222222222222222222222222222',
        `GIT_SYNC_IMAGE=${image}`,
        '',
      ].join('\n'),
    ),
  ).toBe(image);
});

test.each([
  ['a file with no GIT_SYNC_IMAGE line', 'BOXXY_BASE_IMAGE=example.invalid/base:1\n'],
  ['an image with no digest', 'GIT_SYNC_IMAGE=registry.k8s.io/git-sync/git-sync:v4.8.0\n'],
  ['a commented line', `# GIT_SYNC_IMAGE=${setupTest()}\n`],
])('#parseGitSyncImage throws for %s', (_name, text) => {
  expect(() => parseGitSyncImage(text)).toThrowWithMessage(
    Error,
    'images/boxxy/versions.env has no GIT_SYNC_IMAGE line of the form <image>:<tag>@sha256:<digest>',
  );
});

test("#readGitSyncImage reads the repo's own pin", () => {
  expect(readGitSyncImage()).toStartWith('registry.k8s.io/git-sync/git-sync:');
});

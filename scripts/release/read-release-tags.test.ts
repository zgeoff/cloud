import { expect, test } from 'bun:test';
import { buildStubReleaseGH } from '../test-utils/build-stub-release-gh.ts';
import { buildStubRunner } from '../test-utils/build-stub-runner.ts';
import { readReleaseTags } from './read-release-tags.ts';

test('it reads the tags of the latest published releases, newest first', async () => {
  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: { 'zgeoff/nixie': [{ tag: 'v0.32.0' }, { tag: 'v0.31.0' }] },
    }),
  );

  const tags = await readReleaseTags(stub.run, 'zgeoff/nixie');

  expect(tags).toStrictEqual(['v0.32.0', 'v0.31.0']);
});

test('it asks gh for the latest 30 releases that are neither drafts nor prereleases', async () => {
  const stub = buildStubRunner(buildStubReleaseGH({ releases: { 'zgeoff/nixie': [] } }));

  await readReleaseTags(stub.run, 'zgeoff/nixie');

  expect(stub.calls.map((call) => call.argv)).toStrictEqual([
    [
      'gh',
      'release',
      'list',
      '-R',
      'zgeoff/nixie',
      '--exclude-drafts',
      '--exclude-pre-releases',
      '--limit',
      '30',
      '--json',
      'tagName',
    ],
  ]);
});

test('it gives the gh error when the list fails', async () => {
  const stub = buildStubRunner((call) =>
    call.argv[0] === 'gh'
      ? { exitCode: 1, stderr: 'HTTP 401: Bad credentials (https://api.github.com/graphql)\n' }
      : undefined,
  );

  const tags = await readReleaseTags(stub.run, 'zgeoff/nixie');

  expect(tags).toStrictEqual(
    new Error('HTTP 401: Bad credentials (https://api.github.com/graphql)'),
  );
});

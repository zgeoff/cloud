import { expect, test } from 'bun:test';
import { buildStubReleaseDocker } from '../test-utils/build-stub-release-docker.ts';
import { buildStubReleaseGH } from '../test-utils/build-stub-release-gh.ts';
import { buildStubRunner } from '../test-utils/build-stub-runner.ts';
import { getReleaseRecord } from '../test-utils/get-release-record.ts';
import { readImageDigestValues } from './read-image-digest-values.ts';

test('it reads the tag commit and each image digest at the version tag', async () => {
  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: { 'zgeoff/impz': [{ tag: 'v1.0.1', commit: 'c'.repeat(40) }] },
    }),
    buildStubReleaseDocker({
      manifests: {
        'ghcr.io/zgeoff/imp-host:1.0.1': `sha256:${'3'.repeat(64)}`,
        'ghcr.io/zgeoff/imp-base:1.0.1': `sha256:${'4'.repeat(64)}`,
      },
    }).answer,
  );

  const read = await readImageDigestValues(
    {
      record: getReleaseRecord('imp'),
      version: '1.0.1',
      pinned: ['1.0.0', '1.0.0'],
      run: stub.run,
    },
    ['imp-host', 'imp-base'],
  );

  expect(read).toStrictEqual({
    values: {
      commit: 'c'.repeat(40),
      digests: {
        'imp-host': `sha256:${'3'.repeat(64)}`,
        'imp-base': `sha256:${'4'.repeat(64)}`,
      },
    },
    flags: [],
  });
});

test('it gives the gh error for a tag the repository lacks', async () => {
  const stub = buildStubRunner(buildStubReleaseGH({ releases: { 'zgeoff/impz': [] } }));

  const read = await readImageDigestValues(
    {
      record: getReleaseRecord('imp'),
      version: '1.0.1',
      pinned: ['1.0.0', '1.0.0'],
      run: stub.run,
    },
    ['imp-host', 'imp-base'],
  );

  expect(read).toStrictEqual(new Error('gh: No commit found for SHA: v1.0.1 (HTTP 422)'));
});

test('it gives the buildx error for an image the registry lacks', async () => {
  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: { 'zgeoff/impz': [{ tag: 'v1.0.1', commit: 'c'.repeat(40) }] },
    }),
    buildStubReleaseDocker({
      manifests: { 'ghcr.io/zgeoff/imp-host:1.0.1': `sha256:${'3'.repeat(64)}` },
    }).answer,
  );

  const read = await readImageDigestValues(
    {
      record: getReleaseRecord('imp'),
      version: '1.0.1',
      pinned: ['1.0.0', '1.0.0'],
      run: stub.run,
    },
    ['imp-host', 'imp-base'],
  );

  expect(read).toStrictEqual(new Error('ERROR: ghcr.io/zgeoff/imp-base:1.0.1: not found'));
});

test('it refuses a manifest whose digest is not a sha256 digest', async () => {
  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: { 'zgeoff/impz': [{ tag: 'v1.0.1', commit: 'c'.repeat(40) }] },
    }),
    buildStubReleaseDocker({ manifests: { 'ghcr.io/zgeoff/imp-host:1.0.1': '4'.repeat(64) } })
      .answer,
  );

  const read = await readImageDigestValues(
    {
      record: getReleaseRecord('imp'),
      version: '1.0.1',
      pinned: ['1.0.0', '1.0.0'],
      run: stub.run,
    },
    ['imp-host'],
  );

  expect(read).toStrictEqual(new Error('ghcr.io/zgeoff/imp-host:1.0.1 names no sha256 digest'));
});

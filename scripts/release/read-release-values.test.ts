import { expect, test } from 'bun:test';
import { HttpResponse, http } from 'msw';
import { server } from '../mocks/node.ts';
import { buildStubReleaseDocker } from '../test-utils/build-stub-release-docker.ts';
import { buildStubReleaseGH } from '../test-utils/build-stub-release-gh.ts';
import { buildStubRunner } from '../test-utils/build-stub-runner.ts';
import { getReleaseRecord } from '../test-utils/get-release-record.ts';
import { readReleaseValues } from './read-release-values.ts';

test('it reads an atc release SHA256SUMS for a sums source', async () => {
  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: {
        'zgeoff/atc': [
          {
            tag: '@zgeoff/atc@4.3.0',
            assets: { SHA256SUMS: `${'a'.repeat(64)}  atc-linux-x64\n` },
          },
        ],
      },
    }),
  );

  const read = await readReleaseValues({
    record: getReleaseRecord('atc'),
    version: '4.3.0',
    pinned: ['4.2.0', '4.2.0', '4.2.0'],
    run: stub.run,
  });

  expect(read).toStrictEqual({
    values: { sha256sums: `${'a'.repeat(64)}  atc-linux-x64\n` },
    flags: [],
  });
});

test('it fails without values when the atc release lacks its sums', async () => {
  const stub = buildStubRunner(
    buildStubReleaseGH({ releases: { 'zgeoff/atc': [{ tag: '@zgeoff/atc@4.3.0' }] } }),
  );

  const read = await readReleaseValues({
    record: getReleaseRecord('atc'),
    version: '4.3.0',
    pinned: ['4.2.0', '4.2.0', '4.2.0'],
    run: stub.run,
  });

  expect(read).toStrictEqual(new Error('release not found'));
});

test('it reads the imp commit and both image digests for an image-digests source', async () => {
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

  const read = await readReleaseValues({
    record: getReleaseRecord('imp'),
    version: '1.0.1',
    pinned: ['1.0.0', '1.0.0'],
    run: stub.run,
  });

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

test('it reads the nixie digests and flags from the notes for a release-notes source', async () => {
  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: {
        'zgeoff/nixie': [
          {
            tag: 'v0.32.0',
            notes: `## Migrations\n\n- 0009 adds an index\n\n## Images\n\n- \`ghcr.io/zgeoff/nixie@sha256:${'5'.repeat(64)}\`\n- \`ghcr.io/zgeoff/nixie-web@sha256:${'6'.repeat(64)}\`\n`,
          },
          { tag: 'v0.31.0', notes: '## Images\n' },
        ],
      },
    }),
  );

  const read = await readReleaseValues({
    record: getReleaseRecord('nixie'),
    version: '0.32.0',
    pinned: ['0.31.0', '0.31.0'],
    run: stub.run,
  });

  expect(read).toStrictEqual({
    values: {
      digests: {
        nixie: `sha256:${'5'.repeat(64)}`,
        'nixie-web': `sha256:${'6'.repeat(64)}`,
      },
    },
    flags: ['migrations'],
  });
});

test('it reads the auto-mode package from the npm registry for an npm-tarball source', async () => {
  const stub = buildStubRunner();

  server.use(
    http.get(
      'https://registry.npmjs.org/auto-mode/2.1.0',
      () => new HttpResponse('Not Found', { status: 404 }),
    ),
  );

  const read = await readReleaseValues({
    record: getReleaseRecord('auto-mode'),
    version: '2.1.0',
    pinned: ['2.0.0'],
    run: stub.run,
  });

  expect(read).toStrictEqual(
    new Error('the npm registry answered 404 for https://registry.npmjs.org/auto-mode/2.1.0'),
  );
});

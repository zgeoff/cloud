import { expect, test } from 'bun:test';
import { buildStubReleaseGH } from '../test-utils/build-stub-release-gh.ts';
import { buildStubRunner } from '../test-utils/build-stub-runner.ts';
import { getReleaseRecord } from '../test-utils/get-release-record.ts';
import { readReleaseNotesValues } from './read-release-notes-values.ts';

test('it reads both image digests from the target notes and flags nothing for a plain release', async () => {
  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: {
        'zgeoff/nixie': [
          {
            tag: 'v0.32.0',
            notes: `## Migrations\n\nThis release adds no migration since v0.31.0.\n\n## Images\n\n- \`ghcr.io/zgeoff/nixie@sha256:${'5'.repeat(64)}\`\n- \`ghcr.io/zgeoff/nixie-web@sha256:${'6'.repeat(64)}\`\n- \`ghcr.io/zgeoff/sandbox-node@sha256:${'7'.repeat(64)}\`\n`,
          },
          {
            tag: 'v0.31.0',
            notes: `## Images\n\n- \`ghcr.io/zgeoff/nixie@sha256:${'1'.repeat(64)}\`\n- \`ghcr.io/zgeoff/sandbox-node@sha256:${'7'.repeat(64)}\`\n`,
          },
        ],
      },
    }),
  );

  const read = await readReleaseNotesValues({
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
    flags: [],
  });
});

test('it flags the migrations of a release between the oldest pin and the target', async () => {
  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: {
        'zgeoff/nixie': [
          {
            tag: 'v0.32.0',
            notes: `## Migrations\n\nThis release adds no migration since v0.31.1.\n\n## Images\n\n- \`ghcr.io/zgeoff/nixie@sha256:${'5'.repeat(64)}\`\n- \`ghcr.io/zgeoff/nixie-web@sha256:${'6'.repeat(64)}\`\n`,
          },
          { tag: 'v0.31.1', notes: '## Migrations\n\n- 0008 renames a column\n' },
          { tag: 'v0.31.0', notes: '## Images\n' },
        ],
      },
    }),
  );

  const read = await readReleaseNotesValues({
    record: getReleaseRecord('nixie'),
    version: '0.32.0',
    pinned: ['0.31.1', '0.31.0'],
    run: stub.run,
  });

  if (read instanceof Error) {
    throw read;
  }

  expect(read.flags).toStrictEqual(['migrations']);
});

test('it reads the notes of the target and each release between, in that order, and never the oldest pin', async () => {
  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: {
        'zgeoff/nixie': [
          {
            tag: 'v0.32.0',
            notes: `## Migrations\n\nThis release adds no migration since v0.31.1.\n\n## Images\n\n- \`ghcr.io/zgeoff/nixie@sha256:${'5'.repeat(64)}\`\n- \`ghcr.io/zgeoff/nixie-web@sha256:${'6'.repeat(64)}\`\n`,
          },
          {
            tag: 'v0.31.1',
            notes: '## Migrations\n\nThis release adds no migration since v0.31.0.\n',
          },
          { tag: 'v0.31.0', notes: '## Images\n' },
          { tag: 'v0.30.0', notes: '## Images\n' },
        ],
      },
    }),
  );

  await readReleaseNotesValues({
    record: getReleaseRecord('nixie'),
    version: '0.32.0',
    pinned: ['0.31.1', '0.31.0'],
    run: stub.run,
  });

  expect(stub.calls.map((call) => call.argv.slice(0, 4))).toStrictEqual([
    ['gh', 'release', 'list', '-R'],
    ['gh', 'release', 'view', 'v0.32.0'],
    ['gh', 'release', 'view', 'v0.31.1'],
  ]);
});

test('it fails when the latest 30 releases do not reach the pinned release', async () => {
  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: {
        'zgeoff/nixie': Array.from({ length: 31 }, (_, index) => ({
          tag: `v0.${61 - index}.0`,
          notes: '## Images\n',
        })),
      },
    }),
  );

  const read = await readReleaseNotesValues({
    record: getReleaseRecord('nixie'),
    version: '0.61.0',
    pinned: ['0.31.0', '0.31.0'],
    run: stub.run,
  });

  expect(read).toStrictEqual(
    new Error(
      'the latest 30 nixie releases do not reach the pinned v0.31.0, so the releases between go unread',
    ),
  );
});

test('it fails when the target notes list no digest for an image a pin holds', async () => {
  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: {
        'zgeoff/nixie': [
          {
            tag: 'v0.32.0',
            notes: `## Migrations\n\nThis release adds no migration since v0.31.0.\n\n## Images\n\n- \`ghcr.io/zgeoff/nixie@sha256:${'5'.repeat(64)}\`\n`,
          },
          { tag: 'v0.31.0', notes: '## Images\n' },
        ],
      },
    }),
  );

  const read = await readReleaseNotesValues({
    record: getReleaseRecord('nixie'),
    version: '0.32.0',
    pinned: ['0.31.0', '0.31.0'],
    run: stub.run,
  });

  expect(read).toStrictEqual(
    new Error('the release notes list 0 ghcr.io/zgeoff/nixie-web digests under ## Images, want 1'),
  );
});

test('it reads no digest from outside the Images section', async () => {
  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: {
        'zgeoff/nixie': [
          {
            tag: 'v0.32.0',
            notes: `## Changes\n\n- \`ghcr.io/zgeoff/nixie-web@sha256:${'6'.repeat(64)}\`\n\n## Images\n\n- \`ghcr.io/zgeoff/nixie@sha256:${'5'.repeat(64)}\`\n\n## Migrations\n\n- \`ghcr.io/zgeoff/nixie-web@sha256:${'6'.repeat(64)}\`\n`,
          },
          { tag: 'v0.31.0', notes: '## Images\n' },
        ],
      },
    }),
  );

  const read = await readReleaseNotesValues({
    record: getReleaseRecord('nixie'),
    version: '0.32.0',
    pinned: ['0.31.0', '0.31.0'],
    run: stub.run,
  });

  expect(read).toStrictEqual(
    new Error('the release notes list 0 ghcr.io/zgeoff/nixie-web digests under ## Images, want 1'),
  );
});

test('it gives the gh error when a release in the range has no notes to read', async () => {
  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: { 'zgeoff/nixie': [{ tag: 'v0.32.0' }, { tag: 'v0.31.0', notes: '## Images\n' }] },
    }),
  );

  const read = await readReleaseNotesValues({
    record: getReleaseRecord('nixie'),
    version: '0.32.0',
    pinned: ['0.31.0', '0.31.0'],
    run: stub.run,
  });

  expect(read).toStrictEqual(new Error('release not found'));
});

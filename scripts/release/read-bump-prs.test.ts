import { expect, test } from 'bun:test';
import { buildStubReleaseGH } from '../test-utils/build-stub-release-gh.ts';
import { buildStubRunner } from '../test-utils/build-stub-runner.ts';
import { readBumpPRs } from './read-bump-prs.ts';

test("it reads this repository's open pull requests and skips a fork's", async () => {
  const stub = buildStubRunner(
    buildStubReleaseGH({
      openPRs: [
        {
          autoMergeRequest: null,
          headRefOid: 'a'.repeat(40),
          isCrossRepository: true,
          labels: [],
          number: 31,
          url: 'https://github.com/zgeoff/cloud/pull/31',
        },
        {
          autoMergeRequest: { mergeMethod: 'SQUASH' },
          headRefOid: 'b'.repeat(40),
          isCrossRepository: false,
          labels: [{ name: 'auto-merge' }, { name: 'update:patch' }],
          number: 32,
          url: 'https://github.com/zgeoff/cloud/pull/32',
        },
      ],
    }),
  );

  const prs = await readBumpPRs(
    { cwd: '/work/clone', env: {}, run: stub.run, printOut: () => {}, printErr: () => {} },
    'release-check/nixie',
    'open',
  );

  expect(prs).toStrictEqual([
    {
      number: 32,
      url: 'https://github.com/zgeoff/cloud/pull/32',
      autoMerge: true,
      labels: ['auto-merge', 'update:patch'],
      head: 'b'.repeat(40),
    },
  ]);
});

test('it reads a closed pull request without auto-merge', async () => {
  const stub = buildStubRunner(
    buildStubReleaseGH({
      closedPRs: [{ headRefOid: 'c'.repeat(40), isCrossRepository: false, number: 15 }],
    }),
  );

  const prs = await readBumpPRs(
    { cwd: '/work/clone', env: {}, run: stub.run, printOut: () => {}, printErr: () => {} },
    'release-check/imp',
    'closed',
  );

  expect(prs).toStrictEqual([
    { number: 15, url: '', autoMerge: false, labels: [], head: 'c'.repeat(40) },
  ]);
});

test('it gives the gh error when the list fails', async () => {
  const stub = buildStubRunner();

  const prs = await readBumpPRs(
    { cwd: '/work/clone', env: {}, run: stub.run, printOut: () => {}, printErr: () => {} },
    'release-check/imp',
    'open',
  );

  expect(prs).toStrictEqual(
    new Error(
      'unexpected: ["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/imp","--state","open","--json","number,url,autoMergeRequest,labels,headRefOid,isCrossRepository"]',
    ),
  );
});

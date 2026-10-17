import { expect, test } from 'bun:test';
import { buildStubReleaseGH } from '../test-utils/build-stub-release-gh.ts';
import { buildStubRunner } from '../test-utils/build-stub-runner.ts';
import { updateBumpLabels } from './update-bump-labels.ts';

test('it edits no labels when the pull request already carries them', async () => {
  const stub = buildStubRunner(buildStubReleaseGH({}));

  const result = await updateBumpLabels(
    { cwd: '/work/clone', env: {}, run: stub.run, printOut: () => {}, printErr: () => {} },
    {
      number: 14,
      url: 'https://github.com/zgeoff/cloud/pull/14',
      autoMerge: false,
      labels: ['auto-merge', 'update:patch'],
      head: 'a'.repeat(40),
    },
    { wanted: ['update:patch', 'auto-merge'], keepHold: false },
  );

  expect(result).toBeUndefined();
  expect(stub.calls).toStrictEqual([]);
});

test('it keeps a label the bump does not manage', async () => {
  const stub = buildStubRunner(buildStubReleaseGH({}));

  await updateBumpLabels(
    { cwd: '/work/clone', env: {}, run: stub.run, printOut: () => {}, printErr: () => {} },
    {
      number: 14,
      url: 'https://github.com/zgeoff/cloud/pull/14',
      autoMerge: false,
      labels: ['pinned by hand', 'update:minor'],
      head: 'a'.repeat(40),
    },
    { wanted: ['update:patch', 'auto-merge'], keepHold: false },
  );

  expect(stub.calls.map((call) => call.argv)).toStrictEqual([
    [
      'gh',
      'pr',
      'edit',
      '14',
      '--repo',
      'zgeoff/cloud',
      '--add-label',
      'auto-merge,update:patch',
      '--remove-label',
      'update:minor',
    ],
  ]);
});

test('it gives the gh error when the edit fails', async () => {
  const stub = buildStubRunner();

  const result = await updateBumpLabels(
    { cwd: '/work/clone', env: {}, run: stub.run, printOut: () => {}, printErr: () => {} },
    {
      number: 14,
      url: 'https://github.com/zgeoff/cloud/pull/14',
      autoMerge: false,
      labels: [],
      head: 'a'.repeat(40),
    },
    { wanted: ['update:patch'], keepHold: false },
  );

  expect(result).toStrictEqual(
    new Error(
      'unexpected: ["gh","pr","edit","14","--repo","zgeoff/cloud","--add-label","update:patch"]',
    ),
  );
});

import { expect, test } from 'bun:test';
import { buildStubReleaseGH } from './build-stub-release-gh.ts';
import { buildStubRunner } from './build-stub-runner.ts';

test('it lists the open pull requests with only the fields that --json names', async () => {
  const stub = buildStubRunner(
    buildStubReleaseGH({
      openPRs: [{ number: 7, isCrossRepository: false, title: 'chore(atc): bump atc to 4.12.0' }],
      closedPRs: [{ number: 3, isCrossRepository: false }],
    }),
  );

  const result = await stub.run([
    'gh',
    'pr',
    'list',
    '--repo',
    'zgeoff/cloud',
    '--head',
    'release-check/atc',
    '--state',
    'open',
    '--json',
    'number,isCrossRepository',
  ]);

  expect(result.stdout.toString()).toBe('[{"number":7,"isCrossRepository":false}]\n');
});

test('it lists the closed pull requests for --state closed', async () => {
  const stub = buildStubRunner(
    buildStubReleaseGH({ openPRs: [{ number: 7 }], closedPRs: [{ number: 3, headRefOid: 'a' }] }),
  );

  const result = await stub.run([
    'gh',
    'pr',
    'list',
    '--repo',
    'zgeoff/cloud',
    '--head',
    'release-check/atc',
    '--state',
    'closed',
    '--json',
    'number',
  ]);

  expect(result.stdout.toString()).toBe('[{"number":3}]\n');
});

test('it lists no pull request when the scenario names none', async () => {
  const stub = buildStubRunner(buildStubReleaseGH({}));

  const result = await stub.run([
    'gh',
    'pr',
    'list',
    '--repo',
    'zgeoff/cloud',
    '--head',
    'release-check/imp',
    '--state',
    'open',
    '--json',
    'number',
  ]);

  expect(result.stdout.toString()).toBe('[]\n');
});

test('it prints a pull request view with only the fields that --json names', async () => {
  const stub = buildStubRunner(
    buildStubReleaseGH({ prViews: { 7: { headRefOid: 'abc', labels: [], body: 'unread' } } }),
  );

  const result = await stub.run([
    'gh',
    'pr',
    'view',
    '7',
    '--repo',
    'zgeoff/cloud',
    '--json',
    'headRefOid,labels',
  ]);

  expect(result.stdout.toString()).toBe('{"headRefOid":"abc","labels":[]}\n');
});

test('it fails a view of a number without a pull request as gh does', async () => {
  const stub = buildStubRunner(buildStubReleaseGH({}));

  const result = await stub.run([
    'gh',
    'pr',
    'view',
    '8',
    '--repo',
    'zgeoff/cloud',
    '--json',
    'headRefOid',
  ]);

  expect({ exitCode: result.exitCode, stderr: result.stderr.toString() }).toStrictEqual({
    exitCode: 1,
    stderr:
      'GraphQL: Could not resolve to a PullRequest with the number of 8. (repository.pullRequest)\n',
  });
});

test.each([
  [['--squash', '--match-head-commit', '1111111111111111111111111111111111111111']],
  [['--disable-auto']],
])('it answers a merge with %p with no output', async (flags: readonly string[]) => {
  const stub = buildStubRunner(buildStubReleaseGH({}));

  const result = await stub.run(['gh', 'pr', 'merge', '7', '--repo', 'zgeoff/cloud', ...flags]);

  expect({ exitCode: result.exitCode, stdout: result.stdout.toString() }).toStrictEqual({
    exitCode: 0,
    stdout: '',
  });
});

test('it leaves a call it does not model to the next handler', async () => {
  const stub = buildStubRunner(buildStubReleaseGH({}));

  const result = await stub.run(['gh', 'pr', 'merge', '7', '--repo', 'zgeoff/cloud', '--rebase']);

  expect(result.exitCode).toBe(97);
});

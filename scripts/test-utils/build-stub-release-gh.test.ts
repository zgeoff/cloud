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

test('it lists the latest releases of a repository, newest first, up to the limit', async () => {
  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: {
        'zgeoff/nixie': [{ tag: 'v0.32.0' }, { tag: 'v0.31.1' }, { tag: 'v0.31.0' }],
        'zgeoff/impz': [{ tag: 'v9.0.0' }],
      },
    }),
  );

  const result = await stub.run([
    'gh',
    'release',
    'list',
    '-R',
    'zgeoff/nixie',
    '--exclude-drafts',
    '--exclude-pre-releases',
    '--limit',
    '2',
    '--json',
    'tagName',
  ]);

  expect(result.stdout.toString()).toBe('[{"tagName":"v0.32.0"},{"tagName":"v0.31.1"}]\n');
});

test('it prints a release view of the notes as a body field', async () => {
  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: { 'zgeoff/nixie': [{ tag: 'v0.32.0', notes: '## Images\n\n- a line\n' }] },
    }),
  );

  const result = await stub.run([
    'gh',
    'release',
    'view',
    'v0.32.0',
    '-R',
    'zgeoff/nixie',
    '--json',
    'body',
  ]);

  expect(result.stdout.toString()).toBe('{"body":"## Images\\n\\n- a line\\n"}\n');
});

test('it fails a release view of a tag the repository lacks as gh does', async () => {
  const stub = buildStubRunner(buildStubReleaseGH({ releases: { 'zgeoff/nixie': [] } }));

  const result = await stub.run([
    'gh',
    'release',
    'view',
    'v0.32.0',
    '-R',
    'zgeoff/nixie',
    '--json',
    'body',
  ]);

  expect({ exitCode: result.exitCode, stderr: result.stderr.toString() }).toStrictEqual({
    exitCode: 1,
    stderr: 'release not found\n',
  });
});

test('it prints a downloaded asset on stdout', async () => {
  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: {
        'zgeoff/atc': [
          { tag: '@zgeoff/atc@4.3.0', assets: { SHA256SUMS: 'abc  atc-linux-x64\n' } },
        ],
      },
    }),
  );

  const result = await stub.run([
    'gh',
    'release',
    'download',
    '@zgeoff/atc@4.3.0',
    '-R',
    'zgeoff/atc',
    '-p',
    'SHA256SUMS',
    '-O',
    '-',
  ]);

  expect(result.stdout.toString()).toBe('abc  atc-linux-x64\n');
});

test('it fails a download of an asset the release lacks as gh does', async () => {
  const stub = buildStubRunner(
    buildStubReleaseGH({ releases: { 'zgeoff/atc': [{ tag: '@zgeoff/atc@4.3.0' }] } }),
  );

  const result = await stub.run([
    'gh',
    'release',
    'download',
    '@zgeoff/atc@4.3.0',
    '-R',
    'zgeoff/atc',
    '-p',
    'SHA256SUMS',
    '-O',
    '-',
  ]);

  expect({ exitCode: result.exitCode, stderr: result.stderr.toString() }).toStrictEqual({
    exitCode: 1,
    stderr: 'release not found\n',
  });
});

test('it prints the commit of a release tag', async () => {
  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: { 'zgeoff/impz': [{ tag: 'v1.0.1', commit: 'c'.repeat(40) }] },
    }),
  );

  const result = await stub.run(['gh', 'api', 'repos/zgeoff/impz/commits/v1.0.1', '--jq', '.sha']);

  expect(result.stdout.toString()).toBe(`${'c'.repeat(40)}\n`);
});

test('it fails the commit of a tag the repository lacks with the API 422', async () => {
  const stub = buildStubRunner(buildStubReleaseGH({ releases: { 'zgeoff/impz': [] } }));

  const result = await stub.run(['gh', 'api', 'repos/zgeoff/impz/commits/v1.0.1', '--jq', '.sha']);

  expect({
    exitCode: result.exitCode,
    stdout: result.stdout.toString(),
    stderr: result.stderr.toString(),
  }).toStrictEqual({
    exitCode: 1,
    stdout:
      '{"message":"No commit found for SHA: v1.0.1","documentation_url":"https://docs.github.com/rest/commits/commits#get-a-commit","status":"422"}',
    stderr: 'gh: No commit found for SHA: v1.0.1 (HTTP 422)\n',
  });
});

test('it prints the id of a bot user', async () => {
  const stub = buildStubRunner(buildStubReleaseGH({ users: { 'cloud-release-check[bot]': 4242 } }));

  const result = await stub.run(['gh', 'api', 'users/cloud-release-check%5Bbot%5D', '--jq', '.id']);

  expect(result.stdout.toString()).toBe('4242\n');
});

test('it fails the id of a user GitHub does not know with the API 404', async () => {
  const stub = buildStubRunner(buildStubReleaseGH({}));

  const result = await stub.run(['gh', 'api', 'users/unknown-app%5Bbot%5D', '--jq', '.id']);

  expect({
    exitCode: result.exitCode,
    stdout: result.stdout.toString(),
    stderr: result.stderr.toString(),
  }).toStrictEqual({
    exitCode: 1,
    stdout:
      '{"message":"Not Found","documentation_url":"https://docs.github.com/rest/users/users#get-a-user","status":"404"}',
    stderr: 'gh: Not Found (HTTP 404)\n',
  });
});

test('it answers a forced label create with its color and description with no output', async () => {
  const stub = buildStubRunner(buildStubReleaseGH({}));

  const result = await stub.run([
    'gh',
    'label',
    'create',
    'update:patch',
    '--repo',
    'zgeoff/cloud',
    '--force',
    '--color',
    '0e8a16',
    '--description',
    'a patch release',
  ]);

  expect({ exitCode: result.exitCode, stdout: result.stdout.toString() }).toStrictEqual({
    exitCode: 0,
    stdout: '',
  });
});

test('it prints the new pull request URL for a pr create', async () => {
  const stub = buildStubRunner(buildStubReleaseGH({}));

  const result = await stub.run([
    'gh',
    'pr',
    'create',
    '--repo',
    'zgeoff/cloud',
    '--base',
    'main',
    '--head',
    'release-check/atc',
    '--title',
    'chore(atc): bump atc to 4.3.0',
    '--body-file',
    '-',
    '--label',
    'update:minor,auto-merge',
  ]);

  expect(result.stdout.toString()).toBe('https://github.com/zgeoff/cloud/pull/200\n');
});

test('it prints the pull request URL for a pr edit', async () => {
  const stub = buildStubRunner(buildStubReleaseGH({}));

  const result = await stub.run([
    'gh',
    'pr',
    'edit',
    '31',
    '--repo',
    'zgeoff/cloud',
    '--add-label',
    'needs-review',
  ]);

  expect(result.stdout.toString()).toBe('https://github.com/zgeoff/cloud/pull/31\n');
});

test('it leaves a call it does not model to the next handler', async () => {
  const stub = buildStubRunner(buildStubReleaseGH({}));

  const result = await stub.run(['gh', 'pr', 'merge', '7', '--repo', 'zgeoff/cloud', '--rebase']);

  expect(result.exitCode).toBe(97);
});

import { expect, test } from 'bun:test';
import { buildStubPinPRGh } from './build-stub-pin-pr-gh.ts';
import { buildStubRunner } from './build-stub-runner.ts';

test('it lists the scenario’s open pull requests as gh prints them', async () => {
  const stub = buildStubRunner(
    buildStubPinPRGh({
      openPRs: [
        { autoMergeRequest: null, number: 12, url: 'https://github.com/zgeoff/cloud/pull/12' },
      ],
    }),
  );

  const result = await stub.run(['gh', 'pr', 'list', '--repo', 'zgeoff/cloud', '--json', 'number']);

  expect(result.stdout.toString()).toBe(
    '[{"autoMergeRequest":null,"number":12,"url":"https://github.com/zgeoff/cloud/pull/12"}]\n',
  );
});

test('it turns auto-merge off silently', async () => {
  const stub = buildStubRunner(buildStubPinPRGh({ openPRs: [] }));

  const result = await stub.run([
    'gh',
    'pr',
    'merge',
    '12',
    '--repo',
    'zgeoff/cloud',
    '--disable-auto',
  ]);

  expect(result).toStrictEqual({
    exitCode: 0,
    stdout: Buffer.from(''),
    stderr: Buffer.from(''),
    timedOut: false,
  });
});

test('it prints the new pull request’s URL for a create, and the edited one’s for an edit', async () => {
  const stub = buildStubRunner(buildStubPinPRGh({ openPRs: [] }));

  const created = await stub.run(['gh', 'pr', 'create', '--repo', 'zgeoff/cloud']);
  const edited = await stub.run(['gh', 'pr', 'edit', '12', '--repo', 'zgeoff/cloud']);

  expect(created.stdout.toString()).toBe('https://github.com/zgeoff/cloud/pull/200\n');
  expect(edited.stdout.toString()).toBe('https://github.com/zgeoff/cloud/pull/12\n');
});

test('it fails closed with exit 97 on any other gh call, and leaves other programs alone', async () => {
  const stub = buildStubRunner(buildStubPinPRGh({ openPRs: [] }));

  const merge = await stub.run(['gh', 'pr', 'merge', '12', '--squash']);
  const other = await stub.run(['git', 'status']);

  expect(merge).toStrictEqual({
    exitCode: 97,
    stdout: Buffer.from(''),
    stderr: Buffer.from('unexpected: ["gh","pr","merge","12","--squash"]\n'),
    timedOut: false,
  });

  expect(other.stderr.toString()).toBe('unexpected: ["git","status"]\n');
});

import { expect, test } from 'bun:test';
import { readGitHubToken } from './read-github-token.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';

test('it reads the token gh prints, with gh telemetry and update checks off', async () => {
  const stub = buildStubRunner(() => ({ stdout: 'gh-token-1\n' }));

  const token = await readGitHubToken(stub.run);

  expect(token).toBe('gh-token-1');

  expect(stub.calls.map((call) => call.argv)).toStrictEqual([
    ['gh', 'auth', 'token', '--hostname', 'github.com'],
  ]);

  expect(stub.calls[0]?.options.env).toMatchObject({
    GH_TELEMETRY: '0',
    DO_NOT_TRACK: '1',
    GH_NO_UPDATE_NOTIFIER: '1',
  });
});

test('it reads no token when gh holds none', async () => {
  // gh exits 1 with this message when it holds no token and neither GH_TOKEN nor GITHUB_TOKEN is set
  const stub = buildStubRunner(() => ({
    exitCode: 1,
    stderr: 'no oauth token found for github.com\n',
  }));

  const token = await readGitHubToken(stub.run);

  expect(token).toBeUndefined();
});

test('it reads no token when gh is not installed', async () => {
  const stub = buildStubRunner(() => ({ exitCode: 127, stderr: 'gh: not found\n' }));

  const token = await readGitHubToken(stub.run);

  expect(token).toBeUndefined();
});

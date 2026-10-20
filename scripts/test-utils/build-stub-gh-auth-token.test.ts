import { expect, test } from 'bun:test';
import { buildStubGHAuthToken } from './build-stub-gh-auth-token.ts';
import { buildStubRunner } from './build-stub-runner.ts';

test('it prints the token for github.com, as gh auth token does', async () => {
  const stub = buildStubRunner(buildStubGHAuthToken('gh-token-7'));

  const result = await stub.run(['gh', 'auth', 'token', '--hostname', 'github.com']);

  expect(result).toStrictEqual({
    exitCode: 0,
    stdout: Buffer.from('gh-token-7\n'),
    stderr: Buffer.from(''),
    timedOut: false,
  });
});

test('it leaves another host and another gh command to the next handler', async () => {
  const stub = buildStubRunner(buildStubGHAuthToken('gh-token-7'));

  const otherHost = await stub.run(['gh', 'auth', 'token', '--hostname', 'ghe.example.test']);
  const otherCommand = await stub.run(['gh', 'auth', 'status']);

  expect(otherHost.stderr.toString()).toBe(
    'unexpected: ["gh","auth","token","--hostname","ghe.example.test"]\n',
  );

  expect(otherCommand.stderr.toString()).toBe('unexpected: ["gh","auth","status"]\n');
});

import { expect, test } from 'bun:test';
import { pullDeployedHostTag } from './pull-deployed-host-tag.ts';
import { buildStubRunner } from './src/test-utils/build-stub-runner.ts';

test('it fetches the deployed host tag into the clone', async () => {
  const stub = buildStubRunner(() => ({}));

  await pullDeployedHostTag(stub, '/clone');

  expect(stub.calls.map((call) => call.argv)).toStrictEqual([
    [
      'git',
      '-C',
      '/clone',
      'fetch',
      '-q',
      'origin',
      '+refs/tags/deployed/host:refs/tags/deployed/host',
    ],
  ]);
});

test('it throws when the deployed host tag cannot be fetched', () => {
  const loading = pullDeployedHostTag(
    buildStubRunner(() => ({ exitCode: 128, stderr: "fatal: couldn't find remote ref\n" })),
    '/clone',
  );

  expect(loading).rejects.toThrow(
    "git fetch of deployed/host failed: fatal: couldn't find remote ref",
  );
});

import { expect, test } from 'bun:test';
import { findOpenATCPinPR } from './find-open-atc-pin-pr.ts';
import { buildStubPinPRGh } from './test-utils/build-stub-pin-pr-gh.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';

test('it finds the open pull request and whether auto-merge is on', async () => {
  const stub = buildStubRunner(
    buildStubPinPRGh({
      openPRs: [
        {
          autoMergeRequest: { mergeMethod: 'SQUASH' },
          number: 12,
          url: 'https://github.com/zgeoff/cloud/pull/12',
        },
      ],
    }),
  );

  const pr = await findOpenATCPinPR(
    { run: stub.run, printOut: () => {}, printErr: () => {} },
    'zgeoff/cloud',
    'atc-pin/agent-image',
  );

  expect(pr).toStrictEqual({
    number: 12,
    url: 'https://github.com/zgeoff/cloud/pull/12',
    hasAutoMerge: true,
  });
});

test('it reads a null autoMergeRequest as auto-merge off', async () => {
  const stub = buildStubRunner(
    buildStubPinPRGh({
      openPRs: [
        { autoMergeRequest: null, number: 12, url: 'https://github.com/zgeoff/cloud/pull/12' },
      ],
    }),
  );

  const pr = await findOpenATCPinPR(
    { run: stub.run, printOut: () => {}, printErr: () => {} },
    'zgeoff/cloud',
    'atc-pin/agent-image',
  );

  expect(pr?.hasAutoMerge).toBe(false);
});

test('it finds nothing when no pull request is open', async () => {
  const stub = buildStubRunner(buildStubPinPRGh({ openPRs: [] }));

  const pr = await findOpenATCPinPR(
    { run: stub.run, printOut: () => {}, printErr: () => {} },
    'zgeoff/cloud',
    'atc-pin/agent-image',
  );

  expect(pr).toBeUndefined();
});

test('it stops with gh’s exit code when the listing fails', () => {
  const stub = buildStubRunner(() => ({ exitCode: 4, stderr: 'HTTP 401: Bad credentials\n' }));

  expect(
    findOpenATCPinPR(
      { run: stub.run, printOut: () => {}, printErr: () => {} },
      'zgeoff/cloud',
      'atc-pin/agent-image',
    ),
  ).rejects.toMatchObject({ exitCode: 4 });
});

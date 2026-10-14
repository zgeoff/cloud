import { expect, test } from 'bun:test';
import { runHostCheck } from './run-host-check.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';

test('it sends the command as one line with each word quoted, over a batch ssh with a connect timeout', async () => {
  const stub = buildStubRunner(() => ({}));

  await runHostCheck({ run: stub.run, host: 'geoffcloud' }, ['curl', '-H', "Host: it's"]);

  expect(stub.calls[0]?.argv).toStrictEqual([
    'ssh',
    '-o',
    'BatchMode=yes',
    '-o',
    'ConnectTimeout=15',
    'root@geoffcloud',
    String.raw`'curl' '-H' 'Host: it'\''s'`,
  ]);

  expect(stub.calls[0]?.options).toStrictEqual({ timeoutMs: 120_000 });
});

test('it passes the caller’s stdin and timeout through', async () => {
  const stub = buildStubRunner(() => ({}));

  await runHostCheck({ run: stub.run, host: 'geoffcloud' }, ['bash', '-s'], {
    stdin: Buffer.from('echo hi\n'),
    timeoutMs: 5000,
  });

  expect(stub.calls[0]?.stdin).toBe('echo hi\n');
  expect(stub.calls[0]?.options.timeoutMs).toBe(5000);
});

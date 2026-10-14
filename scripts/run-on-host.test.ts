import { expect, test } from 'bun:test';
import { runOnHost } from './run-on-host.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';

test('it runs the command as root on the host through ssh in batch mode, and returns its stdout', async () => {
  const stub = buildStubRunner(() => ({ stdout: 'gateway-token\n' }));

  const stdout = await runOnHost(
    { run: stub.run, printOut: () => {}, printErr: () => {}, host: 'root@geoffcloud' },
    ["ls '/var/lib/atc-daemon-secrets'"],
  );

  expect(stdout).toBe('gateway-token\n');

  expect(stub.calls).toStrictEqual([
    {
      argv: ['ssh', '-o', 'BatchMode=yes', 'root@geoffcloud', "ls '/var/lib/atc-daemon-secrets'"],
      stdin: '',
      options: {},
    },
  ]);
});

test('it sends the stdin it gets on ssh’s stdin', async () => {
  const stub = buildStubRunner(() => ({}));

  await runOnHost(
    { run: stub.run, printOut: () => {}, printErr: () => {}, host: 'root@geoffcloud' },
    ['bash', '-s'],
    Buffer.from('echo hi\n'),
  );

  expect(stub.calls.map((call) => call.stdin)).toStrictEqual(['echo hi\n']);
});

test('it stops with ssh’s exit code when the command fails', () => {
  const stub = buildStubRunner(() => ({ exitCode: 255 }));

  expect(
    runOnHost({ run: stub.run, printOut: () => {}, printErr: () => {}, host: 'root@geoffcloud' }, [
      'true',
    ]),
  ).rejects.toMatchObject({ exitCode: 255 });
});

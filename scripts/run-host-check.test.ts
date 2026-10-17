import { expect, test } from 'bun:test';
import { runHostCheck, runOnHost } from './run-host-check.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';
import { buildStubWordEchoHost } from './test-utils/build-stub-word-echo-host.ts';

test('#runHostCheck it sends the command as one line with each word quoted, over a batch ssh with a connect timeout', async () => {
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

test('#runHostCheck it passes the caller’s stdin and timeout through', async () => {
  const stub = buildStubRunner(() => ({}));

  await runHostCheck({ run: stub.run, host: 'geoffcloud' }, ['bash', '-s'], {
    stdin: Buffer.from('echo hi\n'),
    timeoutMs: 5000,
  });

  expect(stub.calls[0]?.stdin).toBe('echo hi\n');
  expect(stub.calls[0]?.options.timeoutMs).toBe(5000);
});

test('#runOnHost it hands each word to the host’s shell as one word, a space, a quote or a shell character in it included', async () => {
  const stub = buildStubRunner(buildStubWordEchoHost());

  const stdout = await runOnHost(
    { run: stub.run, printOut: () => {}, printErr: () => {}, host: 'geoffcloud' },
    ['stat', '-c', '%n %U %a %s bytes', "/var/lib/it's here", '$HOME', '*', 'a;b'],
  );

  expect(stdout).toBe(
    "[stat]\n[-c]\n[%n %U %a %s bytes]\n[/var/lib/it's here]\n[$HOME]\n[*]\n[a;b]\n",
  );
});

test('#runOnHost it runs the command as root on the host through the batch ssh, and returns its stdout', async () => {
  const stub = buildStubRunner(() => ({ stdout: 'gateway-token\n' }));

  const stdout = await runOnHost(
    { run: stub.run, printOut: () => {}, printErr: () => {}, host: 'geoffcloud' },
    ['ls', '/var/lib/atc-daemon-secrets'],
  );

  expect(stdout).toBe('gateway-token\n');

  expect(stub.calls).toStrictEqual([
    {
      argv: [
        'ssh',
        '-o',
        'BatchMode=yes',
        '-o',
        'ConnectTimeout=15',
        'root@geoffcloud',
        "'ls' '/var/lib/atc-daemon-secrets'",
      ],
      stdin: '',
      options: { timeoutMs: 120_000 },
    },
  ]);
});

test('#runOnHost it sends the stdin it gets on ssh’s stdin', async () => {
  const stub = buildStubRunner(() => ({}));

  await runOnHost(
    { run: stub.run, printOut: () => {}, printErr: () => {}, host: 'geoffcloud' },
    ['bash', '-s'],
    Buffer.from('echo hi\n'),
  );

  expect(stub.calls.map((call) => call.stdin)).toStrictEqual(['echo hi\n']);
});

test('#runOnHost it stops with ssh’s exit code when the command fails, and passes its stderr through', async () => {
  const stub = buildStubRunner(() => ({ exitCode: 255, stderr: 'ssh: connect refused\n' }));
  const errors: string[] = [];

  const io = {
    run: stub.run,
    printOut: () => {},
    printErr: (text: string) => errors.push(text),
    host: 'geoffcloud',
  };

  const failure = await runOnHost(io, ['true']).then(
    () => null,
    (error: unknown) => error,
  );

  expect(failure).toMatchObject({ exitCode: 255 });
  expect(errors).toStrictEqual(['ssh: connect refused\n']);
});

test('#runOnHost it stops with 124 when the command outlives its timeout', () => {
  const stub = buildStubRunner(() => ({ exitCode: 143, timedOut: true }));

  expect(
    runOnHost({ run: stub.run, printOut: () => {}, printErr: () => {}, host: 'geoffcloud' }, [
      'true',
    ]),
  ).rejects.toMatchObject({ exitCode: 124 });
});

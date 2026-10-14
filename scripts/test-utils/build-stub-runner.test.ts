import { expect, test } from 'bun:test';
import { buildStubRunner } from './build-stub-runner.ts';

test('it answers with the first handler that answers, and records the call', async () => {
  const stub = buildStubRunner(
    () => {},
    (call) =>
      call.argv[0] === 'git' ? { stdout: 'main\n', stderr: 'note\n', exitCode: 0 } : undefined,
    () => ({ stdout: 'never\n' }),
  );

  const result = await stub.run(['git', 'branch', '--show-current'], {
    stdin: Buffer.from('in\n'),
    timeoutMs: 1000,
  });

  expect(result).toStrictEqual({
    exitCode: 0,
    stdout: Buffer.from('main\n'),
    stderr: Buffer.from('note\n'),
    timedOut: false,
  });

  expect(stub.calls).toStrictEqual([
    {
      argv: ['git', 'branch', '--show-current'],
      stdin: 'in\n',
      options: { timeoutMs: 1000 },
    },
  ]);
});

test('it fails a call no handler answers with exit 97, as a stand-in’s unknown command does', async () => {
  const stub = buildStubRunner();

  const result = await stub.run(['ssh', 'root@geoffcloud', 'true']);

  expect(result).toStrictEqual({
    exitCode: 97,
    stdout: Buffer.from(''),
    stderr: Buffer.from('unexpected: ["ssh","root@geoffcloud","true"]\n'),
    timedOut: false,
  });
});

test('it reports a timeout a handler answers', async () => {
  const stub = buildStubRunner(() => ({ exitCode: 143, timedOut: true }));

  const result = await stub.run(['imp', 'image', 'build']);

  expect(result.timedOut).toBe(true);
  expect(result.exitCode).toBe(143);
});

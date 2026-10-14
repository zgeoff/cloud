// the first test arranges a real command and two steps and asserts each outcome on its own
/* oxlint-disable max-statements */
import { expect, mock, onTestFinished, test } from 'bun:test';
import { EventEmitter } from 'node:events';
import { ExitError } from './exit-error.ts';
import type { RunResult, Runner } from './run-process.ts';
import { runProcess } from './run-process.ts';
import { subscribeToInterrupts } from './subscribe-to-interrupts.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';

interface TestConfig {
  readonly run: Runner;
}

// a trap over an emitter that stands in for process, with recorders for stderr and the exit
function setupTest(config: TestConfig) {
  // process, which the trap listens to in a script, is an EventEmitter
  // oxlint-disable-next-line unicorn/prefer-event-target
  const signals = new EventEmitter();

  const err: string[] = [];
  const exited = Promise.withResolvers<number>();

  const exit = mock((code: number) => {
    exited.resolve(code);
  });

  const trap = subscribeToInterrupts({
    signals,
    exit,
    run: config.run,
    printOut: () => {},
    printErr: (text) => {
      err.push(text);
    },
  });

  onTestFinished(() => {
    trap.unsubscribe();
  });

  return { signals, trap, err, exit, exited: exited.promise };
}

test('it kills the running command, runs the steps newest first, and exits 130 on SIGINT', async () => {
  const killed = Promise.withResolvers<RunResult>();

  const ctx = setupTest({
    // RunOptions carries stdin as a Buffer, which has no readonly form
    // oxlint-disable-next-line typescript/prefer-readonly-parameter-types
    run: async (argv, options) => {
      const result = await runProcess(argv, options);

      killed.resolve(result);

      return result;
    },
  });

  const ran: string[] = [];

  ctx.trap.registerCleanup(() => ran.push('remove the work directory'));
  ctx.trap.registerCleanup(() => ran.push('remove the check imp'));
  void ctx.trap.run(['tail', '-f', '/dev/null']);
  ctx.signals.emit('SIGINT');

  const exitCode = await ctx.exited;
  const result = await killed.promise;

  expect(exitCode).toBe(130);
  expect(result.exitCode).toBe(143);
  expect(ran).toStrictEqual(['remove the check imp', 'remove the work directory']);
  expect(ctx.err).toStrictEqual(['stopped by SIGINT; cleaning up\n']);
});

test.each([
  ['SIGHUP', 129],
  ['SIGINT', 130],
  ['SIGTERM', 143],
])('it exits on %s with %d, as bash does', async (signal, code) => {
  const ctx = setupTest({ run: buildStubRunner().run });

  ctx.signals.emit(signal);

  const exitCode = await ctx.exited;

  expect(exitCode).toBe(code);
});

test('it starts no command of the script after an interrupt', async () => {
  const stub = buildStubRunner(() => ({}));
  const ctx = setupTest({ run: stub.run });

  ctx.signals.emit('SIGTERM');
  void ctx.trap.run(['imp', 'image', 'rm', 'agent-abc1234']);

  await ctx.exited;

  expect(stub.calls).toStrictEqual([]);
});

test('it never hands the script the result of a command that ends after an interrupt', async () => {
  const answered = Promise.withResolvers<undefined>();

  const stub = buildStubRunner(async () => {
    await answered.promise;

    return { exitCode: 143 };
  });

  const ctx = setupTest({ run: stub.run });
  const settled = mock();

  // the cleanup ends only once the command has ended and every callback it queued has run
  ctx.trap.registerCleanup(async () => {
    const drained = Promise.withResolvers<undefined>();

    answered.resolve(undefined);

    setImmediate(drained.resolve);

    await drained.promise;
  });

  void (async () => {
    await ctx.trap.run(['imp', 'new', 'agent-check-abc1234', '--image', 'agent-abc1234']);

    settled();
  })();

  ctx.signals.emit('SIGTERM');

  await ctx.exited;

  expect(settled).not.toHaveBeenCalled();
});

test('it gives each step a runner that still runs commands after the interrupt', async () => {
  const stub = buildStubRunner(() => ({}));
  const ctx = setupTest({ run: stub.run });

  ctx.trap.registerCleanup((io) => io.run(['imp', 'rm', 'agent-check-abc1234']));
  ctx.signals.emit('SIGINT');

  await ctx.exited;

  expect(stub.calls.map((call) => call.argv)).toStrictEqual([['imp', 'rm', 'agent-check-abc1234']]);
});

test('it prints why a step failed and still runs the steps before it', async () => {
  const ctx = setupTest({ run: buildStubRunner().run });
  const ran: string[] = [];

  ctx.trap.registerCleanup(() => ran.push('remove the work directory'));
  ctx.trap.registerCleanup(() => Promise.reject(new ExitError(1, '')));
  ctx.trap.registerCleanup(() => Promise.reject(new Error('EACCES: permission denied')));
  ctx.signals.emit('SIGTERM');

  const exitCode = await ctx.exited;

  expect(exitCode).toBe(143);
  expect(ran).toStrictEqual(['remove the work directory']);

  expect(ctx.err).toStrictEqual([
    'stopped by SIGTERM; cleaning up\n',
    'EACCES: permission denied\n',
  ]);
});

test('it skips a step that the script dropped after doing it itself', async () => {
  const ctx = setupTest({ run: buildStubRunner().run });
  const ran: string[] = [];

  ctx.trap.registerCleanup(() => ran.push('remove the work directory'));

  const dropCleanup = ctx.trap.registerCleanup(() => ran.push('remove the check imp'));

  dropCleanup();

  ctx.signals.emit('SIGINT');

  await ctx.exited;

  expect(ran).toStrictEqual(['remove the work directory']);
});

test('it runs a step that registers while the cleanup runs', async () => {
  const ctx = setupTest({ run: buildStubRunner().run });
  const ran: string[] = [];

  ctx.trap.registerCleanup(() => {
    ran.push('remove the check imp');
    ctx.trap.registerCleanup(() => ran.push('remove the work directory'));
  });

  ctx.signals.emit('SIGINT');

  await ctx.exited;

  expect(ran).toStrictEqual(['remove the check imp', 'remove the work directory']);
});

test('it ignores a second signal while the cleanup runs', async () => {
  const ctx = setupTest({ run: buildStubRunner().run });
  const released = Promise.withResolvers<undefined>();
  const step = mock(() => released.promise);

  ctx.trap.registerCleanup(step);
  ctx.signals.emit('SIGINT');
  ctx.signals.emit('SIGTERM');
  released.resolve(undefined);

  const exitCode = await ctx.exited;

  expect(exitCode).toBe(130);
  expect(step).toHaveBeenCalledOnce();
  expect(ctx.exit).toHaveBeenCalledOnce();
});

test('it hands the script a command’s result when no signal comes', async () => {
  const stub = buildStubRunner(() => ({ stdout: '[]\n' }));
  const ctx = setupTest({ run: stub.run });

  const result = await ctx.trap.run(['imp', 'ls', '--json']);

  expect(result).toStrictEqual({
    exitCode: 0,
    stdout: Buffer.from('[]\n'),
    stderr: Buffer.from(''),
    timedOut: false,
  });
});

test('it stops listening for every signal on unsubscribe', () => {
  const ctx = setupTest({ run: buildStubRunner().run });

  ctx.trap.unsubscribe();

  expect(
    ['SIGINT', 'SIGTERM', 'SIGHUP'].map((name) => ctx.signals.listenerCount(name)),
  ).toStrictEqual([0, 0, 0]);
});

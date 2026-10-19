import { expect, mock, onTestFinished, test } from 'bun:test';
import { EventEmitter } from 'node:events';
import { existsSync, readFileSync } from 'node:fs';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ExitError } from './exit-error.ts';
import type { RunResult, Runner } from './run-process.ts';
import { runProcess } from './run-process.ts';
import { subscribeToInterrupts } from './subscribe-to-interrupts.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';

interface TestConfig {
  readonly run: Runner;

  // a script's grace when unset
  readonly graceMs?: number;
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
    graceMs: config.graceMs ?? 5000,
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
  void ctx.trap.run(['impz', 'image', 'rm', 'agent-abc1234']);

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

  // the cleanup ends only once every callback that the command's end queued has run
  ctx.trap.registerCleanup(async () => {
    const drained = Promise.withResolvers<undefined>();

    setImmediate(drained.resolve);

    await drained.promise;
  });

  void (async () => {
    await ctx.trap.run(['impz', 'new', 'agent-check-abc1234', '--image', 'agent-abc1234']);

    settled();
  })();

  ctx.signals.emit('SIGTERM');
  answered.resolve(undefined);

  await ctx.exited;

  expect(settled).not.toHaveBeenCalled();
});

test('it waits for a command that traps SIGTERM to exit before it runs the steps', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'subscribe-to-interrupts-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const work = join(directory, 'work');
  const fifo = join(directory, 'trapped');
  const copied = join(directory, 'copied');

  await mkdir(work);
  await writeFile(join(work, 'src'), 'the archived scripts\n');
  await runProcess(['mkfifo', fifo]);

  const ended = Promise.withResolvers<RunResult>();

  const ctx = setupTest({
    run: async (argv, options) => {
      const result = await runProcess(argv, options);

      ended.resolve(result);

      return result;
    },
  });

  ctx.trap.registerCleanup(() => rm(work, { recursive: true, force: true }));

  // The child reads the work tree 0.3 s after its SIGTERM, as a check that cleans up on its own
  // signal does, so a cleanup that did not wait would remove the tree first.
  const trapped =
    'trap \'sleep 0.3; cat "$1/src" > "$2"; exit 0\' TERM; echo > "$3"; while :; do sleep 0.05; done';

  void ctx.trap.run(['bash', '-c', trapped, 'bash', work, copied, fifo]);

  await readFile(fifo);

  ctx.signals.emit('SIGTERM');

  const exitCode = await ctx.exited;
  const result = await ended.promise;
  const text = await readFile(copied, 'utf8');

  expect(exitCode).toBe(143);
  expect(result.exitCode).toBe(0);
  expect(text).toBe('the archived scripts\n');
  expect(existsSync(work)).toBe(false);
});

test('it sends SIGKILL to a command that outlives its SIGTERM by the grace, then runs the steps', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'subscribe-to-interrupts-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const fifo = join(directory, 'trapped');

  await runProcess(['mkfifo', fifo]);

  const ended = Promise.withResolvers<RunResult>();

  const ctx = setupTest({
    graceMs: 50,

    run: async (argv, options) => {
      const result = await runProcess(argv, options);

      ended.resolve(result);

      return result;
    },
  });

  const ran: string[] = [];

  ctx.trap.registerCleanup(() => ran.push('remove the work directory'));

  const ignoring = 'trap "" TERM; echo > "$1"; while :; do sleep 0.05; done';

  void ctx.trap.run(['bash', '-c', ignoring, 'bash', fifo]);

  await readFile(fifo);

  ctx.signals.emit('SIGTERM');

  const exitCode = await ctx.exited;
  const result = await ended.promise;

  expect(exitCode).toBe(143);
  expect(result.exitCode).toBe(137);
  expect(ran).toStrictEqual(['remove the work directory']);

  expect(ctx.err).toStrictEqual([
    'stopped by SIGTERM; cleaning up\n',
    'a command outlived SIGTERM by 50 ms; killing it\n',
  ]);
});

// A descendant that exits leaves a zombie until something reaps it, and a zombie holds no pipe
function isAlive(pid: number) {
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, 'utf8');

    return stat.slice(stat.lastIndexOf(')') + 2, stat.lastIndexOf(')') + 3) !== 'Z';
  } catch {
    return false;
  }
}

// The kernel closes a dying process's pipes a moment before it becomes a zombie, so the test
// polls for the exit. A second is long enough for a SIGKILL and far short of the grandchild's sleep.
async function waitForExit(pid: number) {
  const deadline = performance.now() + 1000;

  while (isAlive(pid) && performance.now() < deadline) {
    await Bun.sleep(5);
  }

  return !isAlive(pid);
}

// The command's Bash starts a grandchild that holds the captured pipes, as an `impz exec` or a
// `curl` in an older commit's check does. The grandchild runs prelude, then writes its pid.
async function runGrandchildCommand(run: Runner, prelude: string) {
  const directory = await mkdtemp(join(tmpdir(), 'subscribe-to-interrupts-'));

  const fifo = join(directory, 'started');
  const pidFile = join(directory, 'pid');

  await runProcess(['mkfifo', fifo]);

  onTestFinished(async () => {
    const text = await readFile(pidFile, 'utf8').catch(() => '0');

    const pid = Number(text);

    if (pid > 0 && isAlive(pid)) {
      process.kill(pid, 'SIGKILL');
    }

    await rm(directory, { recursive: true, force: true });
  });

  const script = `(${prelude}echo $BASHPID > "$1"; echo > "$2"; exec sleep 30) & wait`;

  void run(['bash', '-c', script, 'bash', pidFile, fifo]);

  await readFile(fifo);

  const text = await readFile(pidFile, 'utf8');

  return Number(text);
}

test('it stops a grandchild that holds the command’s pipes, and runs the steps within the grace', async () => {
  const ctx = setupTest({ run: runProcess, graceMs: 2000 });
  const ran: string[] = [];

  ctx.trap.registerCleanup(() => ran.push('remove the check imp'));

  const pid = await runGrandchildCommand(ctx.trap.run, '');

  const started = performance.now();

  ctx.signals.emit('SIGINT');

  const exitCode = await ctx.exited;

  expect(performance.now() - started).toBeLessThan(2000);
  expect(exitCode).toBe(130);
  expect(ran).toStrictEqual(['remove the check imp']);

  const killed = await waitForExit(pid);

  expect(killed).toBe(true);
  expect(ctx.err).toStrictEqual(['stopped by SIGINT; cleaning up\n']);
});

test('it kills a grandchild that ignores SIGTERM and holds the command’s pipes once the grace ends', async () => {
  const ctx = setupTest({ run: runProcess, graceMs: 200 });
  const ran: string[] = [];

  ctx.trap.registerCleanup(() => ran.push('remove the check imp'));

  const pid = await runGrandchildCommand(ctx.trap.run, 'trap "" TERM; ');

  ctx.signals.emit('SIGTERM');

  const exitCode = await ctx.exited;

  expect(exitCode).toBe(143);
  expect(ran).toStrictEqual(['remove the check imp']);

  const killed = await waitForExit(pid);

  expect(killed).toBe(true);

  expect(ctx.err).toStrictEqual([
    'stopped by SIGTERM; cleaning up\n',
    'a command outlived SIGTERM by 200 ms; killing it\n',
  ]);
});

test('it gives each step a runner that still runs commands after the interrupt', async () => {
  const stub = buildStubRunner(() => ({}));
  const ctx = setupTest({ run: stub.run });

  ctx.trap.registerCleanup((io) => io.run(['impz', 'rm', 'agent-check-abc1234']));
  ctx.signals.emit('SIGINT');

  await ctx.exited;

  expect(stub.calls.map((call) => call.argv)).toStrictEqual([
    ['impz', 'rm', 'agent-check-abc1234'],
  ]);
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

  const result = await ctx.trap.run(['impz', 'ls', '--json']);

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

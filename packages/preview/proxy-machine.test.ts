import { expect, mock, onTestFinished, test } from 'bun:test';
import { createActor } from 'xstate';
import type { RunningProxy } from './proxy-machine.ts';
import { proxyMachine } from './proxy-machine.ts';

function setupTest() {
  // a long sleep stands in for a proxy process, so a stop has a real process to kill
  const child = Bun.spawn(['sleep', '30'], { stdin: 'ignore', stdout: 'pipe', stderr: 'inherit' });

  onTestFinished(() => {
    child.kill('SIGKILL');
  });

  return { running: { process: child, origin: 'http://127.0.0.1:41000' } };
}

test('it starts one proxy for the calls that ask during its start and answers each with its origin', async () => {
  const ctx = setupTest();
  const started = Promise.withResolvers<RunningProxy>();
  const startProxy = mock(() => started.promise);
  const actor = createActor(proxyMachine, { input: { imp: 'pv-0a1b2c3d-7', startProxy } });

  actor.start();

  onTestFinished(() => {
    actor.stop();
  });

  const first = Promise.withResolvers<RunningProxy>();
  const second = Promise.withResolvers<RunningProxy>();

  actor.send({ type: 'hold', waiter: first, nowMs: 1000 });
  actor.send({ type: 'hold', waiter: second, nowMs: 1000 });
  started.resolve(ctx.running);

  const answers = await Promise.all([first.promise, second.promise]);

  expect(answers.map((answer) => answer.origin)).toStrictEqual([
    'http://127.0.0.1:41000',
    'http://127.0.0.1:41000',
  ]);

  expect(startProxy).toHaveBeenCalledOnce();
});

test('it refuses the calls that wait when a stop comes during the start, and kills the started proxy before the stop resolves', async () => {
  const ctx = setupTest();
  const started = Promise.withResolvers<RunningProxy>();

  const actor = createActor(proxyMachine, {
    input: { imp: 'pv-0a1b2c3d-7', startProxy: () => started.promise },
  });

  actor.start();

  onTestFinished(() => {
    actor.stop();
  });

  const waiter = Promise.withResolvers<RunningProxy>();
  const stopped = Promise.withResolvers<undefined>();

  // settled at once, so the refusal is held until the test reads it
  const holding = Promise.allSettled([waiter.promise]);

  actor.send({ type: 'hold', waiter, nowMs: 1000 });

  actor.send({
    type: 'stop',
    done: () => {
      stopped.resolve(undefined);
    },
  });

  started.resolve(ctx.running);

  await stopped.promise;

  // read at once, as the stop resolves
  const ended = ctx.running.process.signalCode;

  const [refused] = await holding;

  expect(refused).toMatchObject({
    status: 'rejected',
    reason: { message: 'the counting proxy for pv-0a1b2c3d-7 was stopped' },
  });

  expect(ended).toBe('SIGTERM');
});

test('it refuses the calls that wait with the error of a start that fails', async () => {
  const actor = createActor(proxyMachine, {
    input: {
      imp: 'pv-0a1b2c3d-7',
      startProxy: () =>
        Promise.reject(new Error('the counting proxy for pv-0a1b2c3d-7 did not start')),
    },
  });

  actor.start();

  onTestFinished(() => {
    actor.stop();
  });

  const waiter = Promise.withResolvers<RunningProxy>();
  const holding = Promise.allSettled([waiter.promise]);

  actor.send({ type: 'hold', waiter, nowMs: 1000 });

  const [refused] = await holding;

  expect(refused).toMatchObject({
    status: 'rejected',
    reason: { message: 'the counting proxy for pv-0a1b2c3d-7 did not start' },
  });

  expect(actor.getSnapshot().context.holds).toBe(0);
});

test('it keeps a running proxy through an idle check while a call holds it', async () => {
  const ctx = setupTest();

  const actor = createActor(proxyMachine, {
    input: { imp: 'pv-0a1b2c3d-7', startProxy: () => Promise.resolve(ctx.running) },
  });

  actor.start();

  onTestFinished(() => {
    actor.stop();
  });

  const waiter = Promise.withResolvers<RunningProxy>();

  actor.send({ type: 'hold', waiter, nowMs: 1000 });

  await waiter.promise;

  const checked = Promise.withResolvers<undefined>();

  actor.send({
    type: 'idle',
    cutoffMs: 5000,
    done: () => {
      checked.resolve(undefined);
    },
  });

  await checked.promise;

  expect(actor.getSnapshot().value).toBe('running');
});

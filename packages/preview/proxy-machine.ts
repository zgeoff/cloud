import { machineTypes } from '@zgeoff/std';
import type { ActorRef, Snapshot } from 'xstate';
import { assign, fromPromise, setup } from 'xstate';
import type { ProxyProcess } from './build-spend-proxy-io.ts';

export interface RunningProxy {
  readonly process: ProxyProcess;
  readonly origin: string;
}

export interface ProxyMachineInput {
  readonly imp: string;
  readonly startProxy: () => Promise<RunningProxy>;
}

type ProxyWaiter = PromiseWithResolvers<RunningProxy>;

interface ProxyContext {
  readonly input: ProxyMachineInput;
  readonly running: RunningProxy | null;

  // every call that asked for the proxy and has not released it, started or not, so the idle
  // sweep never stops a proxy that a call waits on
  readonly holds: number;
  readonly lastUsedMs: number;

  // the calls that wait for a start, and the stops that wait for the process to exit
  readonly waiters: readonly ProxyWaiter[];
  readonly stopWaiters: readonly (() => void)[];

  // a stop that came during a start, which runs once the start has a process to kill
  readonly isStopAsked: boolean;
}

type ProxyEvent =
  | { readonly type: 'hold'; readonly waiter: ProxyWaiter; readonly nowMs: number }
  | { readonly type: 'release'; readonly nowMs: number }
  | { readonly type: 'idle'; readonly cutoffMs: number; readonly done: () => void }
  | { readonly type: 'stop'; readonly done: () => void }
  | { readonly type: 'exited'; readonly process: ProxyProcess };

// A new start waits until the old process has exited, so two proxies never write one count, and
// each stop resolves only once its process has exited.
export const proxyMachine = setup({
  types: machineTypes<{
    input: ProxyMachineInput;
    context: ProxyContext;
    events: ProxyEvent;
  }>(),
  actors: {
    start: fromPromise<RunningProxy, ProxyMachineInput>((start) => start.input.startProxy()),
    kill: fromPromise<void, RunningProxy | null>((kill) => runKill(kill.input)),
  },
  actions: {
    addHold: assign((held) => {
      const event = held.event;

      return event.type === 'hold'
        ? {
            holds: held.context.holds + 1,
            lastUsedMs: event.nowMs,
            waiters: [...held.context.waiters, event.waiter],
          }
        : {};
    }),
    removeHold: assign((released) => {
      const event = released.event;

      return event.type === 'release'
        ? { holds: released.context.holds - 1, lastUsedMs: event.nowMs }
        : {};
    }),
    resolveWaiters: assign((ready) => {
      const running = ready.context.running;

      if (running !== null) {
        for (const waiter of ready.context.waiters) {
          waiter.resolve(running);
        }
      }

      return { waiters: [] };
    }),
    rejectWaiters: assign((refused) => {
      const error = new Error(`the counting proxy for ${refused.context.input.imp} was stopped`);

      for (const waiter of refused.context.waiters) {
        waiter.reject(error);
      }

      return { holds: refused.context.holds - refused.context.waiters.length, waiters: [] };
    }),
    addStopWaiter: assign((stopped) => {
      const event = stopped.event;

      return event.type === 'stop' || event.type === 'idle'
        ? { stopWaiters: [...stopped.context.stopWaiters, event.done] }
        : {};
    }),
    resolveStopWaiters: assign((stopped) => {
      for (const done of stopped.context.stopWaiters) {
        done();
      }

      return { stopWaiters: [], running: null, isStopAsked: false };
    }),
    callDone: (asked) => {
      const event = asked.event;

      if (event.type === 'stop' || event.type === 'idle') {
        event.done();
      }
    },
    watchExit: (entered) => {
      const running = entered.context.running;

      if (running !== null) {
        void sendOnExit(running.process, entered.self);
      }
    },
  },
  guards: {
    hasWaiters: (checked) => checked.context.waiters.length > 0,
    isStopAsked: (checked) => checked.context.isStopAsked,
    isIdle: (checked) =>
      checked.event.type === 'idle' &&
      checked.context.holds === 0 &&
      checked.context.lastUsedMs < checked.event.cutoffMs,
    isRunningExit: (checked) =>
      checked.event.type === 'exited' && checked.event.process === checked.context.running?.process,
    hasProcessExited: (checked) => {
      const process = checked.context.running?.process;

      return process !== undefined && (process.exitCode !== null || process.signalCode !== null);
    },
  },
}).createMachine({
  id: 'proxy',
  context: (created) => ({
    input: created.input,
    running: null,
    holds: 0,
    lastUsedMs: 0,
    waiters: [],
    stopWaiters: [],
    isStopAsked: false,
  }),
  initial: 'stopped',
  states: {
    stopped: {
      entry: 'resolveStopWaiters',
      always: { guard: 'hasWaiters', target: 'starting' },
      on: {
        hold: { actions: 'addHold' },
        release: { actions: 'removeHold' },
        idle: { actions: 'callDone' },
        stop: { actions: 'callDone' },
      },
    },
    starting: {
      invoke: {
        // oxlint-disable-next-line zgeoff/no-abbreviated-names -- xstate names the invoked actor `src`
        src: 'start',
        input: (entered) => entered.context.input,
        onDone: [
          {
            guard: 'isStopAsked',
            target: 'stopping',
            actions: assign((started) => ({ running: started.event.output })),
          },
          {
            target: 'running',
            actions: assign((started) => ({ running: started.event.output })),
          },
        ],
        onError: {
          target: 'stopped',
          actions: assign((failed) => {
            for (const waiter of failed.context.waiters) {
              waiter.reject(failed.event.error);
            }

            return { holds: failed.context.holds - failed.context.waiters.length, waiters: [] };
          }),
        },
      },
      on: {
        hold: { actions: 'addHold' },
        release: { actions: 'removeHold' },
        idle: { actions: 'callDone' },
        stop: { actions: ['rejectWaiters', 'addStopWaiter', assign({ isStopAsked: true })] },
      },
    },
    running: {
      entry: ['resolveWaiters', 'watchExit'],
      on: {
        hold: [
          // the proxy can exit before its exit event arrives, so a call that finds it gone starts
          // the next one rather than getting a dead origin
          { guard: 'hasProcessExited', target: 'starting', actions: 'addHold' },
          { actions: ['addHold', 'resolveWaiters'] },
        ],
        release: { actions: 'removeHold' },
        exited: { guard: 'isRunningExit', target: 'stopped' },
        idle: [
          { guard: 'isIdle', target: 'stopping', actions: 'addStopWaiter' },
          { actions: 'callDone' },
        ],
        stop: { target: 'stopping', actions: 'addStopWaiter' },
      },
    },
    stopping: {
      invoke: {
        // oxlint-disable-next-line zgeoff/no-abbreviated-names -- xstate names the invoked actor `src`
        src: 'kill',
        input: (entered) => entered.context.running,
        onDone: { target: 'stopped' },
        onError: { target: 'stopped' },
      },
      on: {
        hold: { actions: 'addHold' },
        release: { actions: 'removeHold' },
        idle: { actions: 'callDone' },
        stop: { actions: ['rejectWaiters', 'addStopWaiter'] },
      },
    },
  },
});

async function runKill(running: RunningProxy | null): Promise<void> {
  running?.process.kill();

  await running?.process.exited;
}

async function sendOnExit(
  process: ProxyProcess,
  self: ActorRef<Snapshot<unknown>, ProxyEvent>,
): Promise<void> {
  await process.exited;

  self.send({ type: 'exited', process });
}

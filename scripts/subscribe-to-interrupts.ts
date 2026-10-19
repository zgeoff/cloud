import { constants } from 'node:os';
import { ExitError } from './exit-error.ts';
import type { ScriptIO } from './run-or-exit.ts';
import type { RunResult, Runner } from './run-process.ts';
import { runProcess } from './run-process.ts';

// a step gets the runner that an interrupt leaves working
type CleanupStep = (io: Readonly<ScriptIO>) => unknown;

export interface InterruptibleIO extends ScriptIO {
  readonly registerCleanup: (step: CleanupStep) => () => void;
}

export interface InterruptTrap extends InterruptibleIO {
  readonly unsubscribe: () => void;
}

const interrupts = ['SIGINT', 'SIGTERM', 'SIGHUP'] as const;

type Interrupt = (typeof interrupts)[number];

interface SignalSource {
  readonly on: (signal: Interrupt, listener: () => void) => unknown;
  readonly off: (signal: Interrupt, listener: () => void) => unknown;
}

export interface InterruptTrapOptions extends ScriptIO {
  readonly signals: SignalSource;
  readonly exit: (code: number) => void;

  readonly graceMs: number;
}

const processTrapOptions: InterruptTrapOptions = {
  signals: process,
  exit: (code) => process.exit(code),
  graceMs: 5000,
  run: runProcess,
  printOut: (text) => {
    process.stdout.write(text);
  },
  printErr: (text) => {
    process.stderr.write(text);
  },
};

export function subscribeToInterrupts(
  options: Readonly<InterruptTrapOptions> = processTrapOptions,
): InterruptTrap {
  const commands: Commands = {
    stop: new AbortController(),
    force: new AbortController(),
    active: new Set(),
  };

  const steps: CleanupStep[] = [];
  const io: ScriptIO = { run: options.run, printOut: options.printOut, printErr: options.printErr };

  const listeners = interrupts.map((signal) => {
    const onInterrupt = () => {
      // a second signal changes nothing, so SIGKILL stops the cleanup
      if (!commands.stop.signal.aborted) {
        commands.stop.abort();
        void runCleanup({ ...options, io, steps, commands }, signal);
      }
    };

    options.signals.on(signal, onInterrupt);

    return { signal, onInterrupt };
  });

  return {
    run: makeParkingRunner(options.run, commands),
    printOut: options.printOut,
    printErr: options.printErr,
    registerCleanup: (step) => {
      steps.push(step);

      return () => {
        const index = steps.lastIndexOf(step);

        if (index !== -1) {
          steps.splice(index, 1);
        }
      };
    },
    unsubscribe: () => {
      for (const listener of listeners) {
        options.signals.off(listener.signal, listener.onInterrupt);
      }
    },
  };
}

interface Commands {
  readonly stop: AbortController;
  readonly force: AbortController;
  readonly active: Set<Promise<RunResult>>;
}

function makeParkingRunner(run: Runner, commands: Readonly<Commands>): Runner {
  const parked = Promise.withResolvers<RunResult>().promise;

  return async (argv, options = {}) => {
    // after an interrupt the script parks at its next command until the cleanup exits the process
    if (commands.stop.signal.aborted) {
      return parked;
    }

    const running = run(argv, {
      ...options,
      signal: commands.stop.signal,
      forceStop: commands.force.signal,
    });

    const result = await waitForCommand(commands.active, running);

    return commands.stop.signal.aborted ? parked : result;
  };
}

async function waitForCommand(active: Set<Promise<RunResult>>, running: Promise<RunResult>) {
  active.add(running);

  try {
    return await running;
  } finally {
    active.delete(running);
  }
}

interface Cleanup {
  readonly io: Readonly<ScriptIO>;
  readonly steps: CleanupStep[];
  readonly commands: Readonly<Commands>;
  readonly graceMs: number;
  readonly exit: (code: number) => void;
}

async function runCleanup(cleanup: Readonly<Cleanup>, signal: Interrupt) {
  cleanup.io.printErr(`stopped by ${signal}; cleaning up\n`);

  // no step starts while a command of the script runs, since a command that traps SIGTERM can
  // still read what a step removes
  await waitForCommands(cleanup);

  // a step that registers while the cleanup runs, such as one whose mkdtemp was in flight, still
  // runs
  for (let step = cleanup.steps.pop(); step !== undefined; step = cleanup.steps.pop()) {
    await tryCleanupStep(cleanup.io, step);
  }

  cleanup.exit(128 + constants.signals[signal]);
}

async function waitForCommands(cleanup: Readonly<Cleanup>) {
  const exited = Promise.allSettled(cleanup.commands.active);
  const timer = Promise.withResolvers<'timeout'>();

  const timeout = setTimeout(() => {
    timer.resolve('timeout');
  }, cleanup.graceMs);

  const first = await Promise.race([exited, timer.promise]);

  clearTimeout(timeout);

  if (first === 'timeout') {
    cleanup.io.printErr(`a command outlived SIGTERM by ${cleanup.graceMs} ms; killing it\n`);
    cleanup.commands.force.abort();

    await exited;
  }
}

async function tryCleanupStep(io: Readonly<ScriptIO>, step: CleanupStep) {
  try {
    await step(io);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);

    if (!(error instanceof ExitError) || message !== '') {
      io.printErr(`${message}\n`);
    }
  }
}

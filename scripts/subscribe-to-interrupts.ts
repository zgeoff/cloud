// RunOptions carries stdin as a Buffer, which has no readonly form
/* oxlint-disable typescript/prefer-readonly-parameter-types */
import { constants } from 'node:os';
import { ExitError } from './exit-error.ts';
import type { ScriptIO } from './run-or-exit.ts';
import type { RunResult, Runner } from './run-process.ts';
import { runProcess } from './run-process.ts';

// a step that undoes what the script made; it gets the runner that an interrupt leaves working
type CleanupStep = (io: Readonly<ScriptIO>) => unknown;

export interface InterruptibleIO extends ScriptIO {
  // adds a step that runs on an interrupt, and returns the function that drops it once the
  // script has done the step itself
  readonly registerCleanup: (step: CleanupStep) => () => void;
}

export interface InterruptTrap extends InterruptibleIO {
  readonly unsubscribe: () => void;
}

// the signals that stop a script, which the shell scripts' `trap … EXIT` also covered
const interrupts = ['SIGINT', 'SIGTERM', 'SIGHUP'] as const;

type Interrupt = (typeof interrupts)[number];

// process in a script; a test passes an EventEmitter
interface SignalSource {
  readonly on: (signal: Interrupt, listener: () => void) => unknown;
  readonly off: (signal: Interrupt, listener: () => void) => unknown;
}

export interface InterruptTrapOptions extends ScriptIO {
  readonly signals: SignalSource;
  readonly exit: (code: number) => void;
}

// the script's own process, which a script's entry point traps
const processTrapOptions: InterruptTrapOptions = {
  signals: process,
  exit: (code) => process.exit(code),
  run: runProcess,
  printOut: (text) => {
    process.stdout.write(text);
  },
  printErr: (text) => {
    process.stderr.write(text);
  },
};

// The cleanup that `trap … EXIT` gave the shell scripts: on a signal, it kills the running command,
// starts no later one, runs the registered steps newest first, and exits 128 plus the signal's
// number. A failed step prints why; a second signal changes nothing, so SIGKILL stops the cleanup.
export function subscribeToInterrupts(
  options: Readonly<InterruptTrapOptions> = processTrapOptions,
): InterruptTrap {
  const controller = new AbortController();

  const steps: CleanupStep[] = [];
  const io: ScriptIO = { run: options.run, printOut: options.printOut, printErr: options.printErr };

  const listeners = interrupts.map((signal) => {
    const onInterrupt = () => {
      if (!controller.signal.aborted) {
        controller.abort();
        void runCleanup({ ...options, io, steps }, signal);
      }
    };

    options.signals.on(signal, onInterrupt);

    return { signal, onInterrupt };
  });

  return {
    run: makeParkingRunner(options.run, controller.signal),
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

// The runner for the script's own steps. An interrupt kills the command that runs, and the script
// parks at it, or at the next command it starts, until the cleanup exits the process.
function makeParkingRunner(run: Runner, signal: AbortSignal): Runner {
  const parked = Promise.withResolvers<RunResult>().promise;

  return async (argv, options = {}) => {
    if (signal.aborted) {
      return parked;
    }

    const result = await run(argv, { ...options, signal });

    return signal.aborted ? parked : result;
  };
}

interface Cleanup {
  readonly io: Readonly<ScriptIO>;
  readonly steps: CleanupStep[];
  readonly exit: (code: number) => void;
}

// a step that registers while the cleanup runs, such as one whose mkdtemp was in flight, still
// runs, so the loop takes the newest step until none is left
async function runCleanup(cleanup: Readonly<Cleanup>, signal: Interrupt) {
  cleanup.io.printErr(`stopped by ${signal}; cleaning up\n`);

  for (let step = cleanup.steps.pop(); step !== undefined; step = cleanup.steps.pop()) {
    // oxlint-disable-next-line no-await-in-loop -- each step undoes what the steps after it built on
    await tryCleanupStep(cleanup.io, step);
  }

  cleanup.exit(128 + constants.signals[signal]);
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

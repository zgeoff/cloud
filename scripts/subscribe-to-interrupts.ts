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

  // how long a command that traps SIGTERM gets to exit before it gets SIGKILL
  readonly graceMs: number;
}

// the script's own process, which a script's entry point traps
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

// The cleanup that `trap … EXIT` gave the shell scripts: on a signal, it stops the running command,
// waits for it to exit, runs the registered steps newest first, and exits 128 plus the signal's
// number. A failed step prints why; a second signal changes nothing, so SIGKILL stops the cleanup.
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

// the script's own commands: stop sends them SIGTERM, force sends them SIGKILL, and active holds
// each one until it exits
interface Commands {
  readonly stop: AbortController;
  readonly force: AbortController;
  readonly active: Set<Promise<RunResult>>;
}

// The runner for the script's own steps. An interrupt stops the command that runs, and the script
// parks at it, or at the next command it starts, until the cleanup exits the process.
function makeParkingRunner(run: Runner, commands: Readonly<Commands>): Runner {
  const parked = Promise.withResolvers<RunResult>().promise;

  return async (argv, options = {}) => {
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

// holds the command in active until it exits
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

// A step that registers while the cleanup runs, such as one whose mkdtemp was in flight, still
// runs, so the loop takes the newest step until none is left. No step starts while a command of
// the script runs, since a command that traps SIGTERM can still read what a step removes.
async function runCleanup(cleanup: Readonly<Cleanup>, signal: Interrupt) {
  cleanup.io.printErr(`stopped by ${signal}; cleaning up\n`);

  await waitForCommands(cleanup);

  for (let step = cleanup.steps.pop(); step !== undefined; step = cleanup.steps.pop()) {
    await tryCleanupStep(cleanup.io, step);
  }

  cleanup.exit(128 + constants.signals[signal]);
}

// gives the commands graceMs to exit on their SIGTERM, then sends SIGKILL to each one left
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

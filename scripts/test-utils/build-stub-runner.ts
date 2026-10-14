// the recorded calls are a mutable list by design
/* oxlint-disable typescript/prefer-readonly-parameter-types */
import type { RunOptions, RunResult, Runner } from '../run-process.ts';

// Stands in for runProcess. It records every call, then hands it to each handler in turn; the
// first handler that answers decides the result. A call no handler answers ends as a stand-in's
// unknown command does: exit 97 and "unexpected: <argv as JSON>" on stderr.
export interface StubCall {
  readonly argv: readonly string[];

  // the stdin the script sent, as text; empty when it sent none
  readonly stdin: string;

  // the call's other options; its stdin is the text above, so a handler sees no Buffer, and no
  // stand-in runs a child that an abort signal could stop
  readonly options: Readonly<Omit<RunOptions, 'stdin' | 'signal' | 'forceStop'>>;
}

export interface StubAnswer {
  readonly exitCode?: number;
  readonly stdout?: string;
  readonly stderr?: string;
  readonly timedOut?: boolean;
}

export type StubHandler = (
  call: StubCall,
) => StubAnswer | undefined | Promise<StubAnswer | undefined>;

export interface StubRunner {
  readonly run: Runner;

  // every call, in order
  readonly calls: readonly StubCall[];
}

export function buildStubRunner(...handlers: readonly StubHandler[]): StubRunner {
  const calls: StubCall[] = [];

  return {
    run: async (argv, options = {}) => {
      const call = {
        argv: [...argv],
        stdin: options.stdin?.toString() ?? '',
        options: toCallOptions(options),
      };

      calls.push(call);

      const answer = await findAnswer(handlers, call);

      return toRunResult(answer);
    },
    calls,
  };
}

async function findAnswer(handlers: readonly StubHandler[], call: StubCall) {
  for (const handler of handlers) {
    // oxlint-disable-next-line no-await-in-loop -- the first handler that answers wins, in order
    const answer = await handler(call);

    if (answer !== undefined) {
      return answer;
    }
  }

  return { exitCode: 97, stderr: `unexpected: ${JSON.stringify(call.argv)}\n` };
}

function toCallOptions(
  options: Readonly<RunOptions>,
): Readonly<Omit<RunOptions, 'stdin' | 'signal' | 'forceStop'>> {
  return {
    ...(options.timeoutMs === undefined ? {} : { timeoutMs: options.timeoutMs }),
    ...(options.cwd === undefined ? {} : { cwd: options.cwd }),
    ...(options.env === undefined ? {} : { env: options.env }),
  };
}

function toRunResult(answer: Readonly<StubAnswer>): RunResult {
  return {
    exitCode: answer.exitCode ?? 0,
    stdout: Buffer.from(answer.stdout ?? ''),
    stderr: Buffer.from(answer.stderr ?? ''),
    timedOut: answer.timedOut ?? false,
  };
}

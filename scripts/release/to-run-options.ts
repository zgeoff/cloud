import type { RunOptions } from '../run-process.ts';
import type { BumpContext } from './types.ts';

// the run options of a command in the bump's clone, with the bump's environment
export function toRunOptions(context: BumpContext, stdin?: string): RunOptions {
  return {
    cwd: context.cwd,
    env: context.env,
    ...(stdin === undefined ? {} : { stdin: Buffer.from(stdin) }),
  };
}

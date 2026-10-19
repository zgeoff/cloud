import type { RunOptions } from '../run-process.ts';
import type { BumpContext } from './types.ts';

export function toRunOptions(context: BumpContext, stdin?: string): RunOptions {
  return {
    cwd: context.cwd,
    env: context.env,
    ...(stdin === undefined ? {} : { stdin: Buffer.from(stdin) }),
  };
}

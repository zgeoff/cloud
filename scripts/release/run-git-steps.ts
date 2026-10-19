import { runChecked } from './run-checked.ts';
import { toRunOptions } from './to-run-options.ts';
import type { BumpContext } from './types.ts';

export async function runGitSteps(
  context: BumpContext,
  steps: readonly (readonly string[])[],
): Promise<Error | undefined> {
  for (const step of steps) {
    const result = await runChecked(context.run, ['git', ...step], toRunOptions(context));

    if (result instanceof Error) {
      return result;
    }
  }

  return undefined;
}

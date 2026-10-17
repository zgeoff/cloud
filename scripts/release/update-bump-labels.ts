import { managedBumpLabels } from './managed-bump-labels.ts';
import { runChecked } from './run-checked.ts';
import { toRunOptions } from './to-run-options.ts';
import type { BumpContext, BumpPR } from './types.ts';

export interface WantedLabels {
  readonly wanted: readonly string[];
  readonly keepHold: boolean;
}

// Adds the labels the open pull request lacks and removes the managed ones it no longer carries.
// With keepHold, a person's needs-review stays, and auto-merge is not added beside it.
export async function updateBumpLabels(
  context: BumpContext,
  pr: BumpPR,
  labels: WantedLabels,
): Promise<Error | undefined> {
  const isHeld = labels.keepHold && pr.labels.includes('needs-review');

  const kept = isHeld
    ? [...labels.wanted.filter((label) => label !== 'auto-merge'), 'needs-review']
    : labels.wanted;

  const wanted = new Set(kept);

  const add = [...wanted].filter((label) => !pr.labels.includes(label)).toSorted();

  const remove = pr.labels
    .filter((label) => !wanted.has(label) && managedBumpLabels.has(label))
    .toSorted();

  const args = [
    ...(add.length > 0 ? ['--add-label', add.join(',')] : []),
    ...(remove.length > 0 ? ['--remove-label', remove.join(',')] : []),
  ];

  if (args.length === 0) {
    return undefined;
  }

  const edited = await runChecked(
    context.run,
    ['gh', 'pr', 'edit', String(pr.number), '--repo', 'zgeoff/cloud', ...args],
    toRunOptions(context),
  );

  return edited instanceof Error ? edited : undefined;
}

import { match } from 'ts-pattern';
import { agentImageAlias } from './constants.ts';
import type { AliasMoveReport, AliasVerdict } from './types.ts';

// Says what the alias move came to, and what to print about it.
export function buildAliasMoveReport(
  verdict: Readonly<AliasVerdict>,
  image: string,
): AliasMoveReport {
  return match(verdict)
    .with({ kind: 'ok' }, () => ({
      outcome: 'moved' as const,
      message: `moved the ${agentImageAlias} alias to ${image}\n`,
    }))
    .with({ kind: 'skip' }, (step) => ({
      outcome: 'skipped' as const,
      message:
        `warning: ${step.reason}, so the ${agentImageAlias} alias stays where it was and does not move ` +
        `to ${image}\n`,
    }))
    .with({ kind: 'fail' }, (step) => ({
      outcome: 'failed' as const,
      message: `could not move the ${agentImageAlias} alias to ${image}; the image stays pinned: ${step.reason}`,
    }))
    .exhaustive();
}

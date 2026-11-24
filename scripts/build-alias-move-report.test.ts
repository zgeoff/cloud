import { expect, test } from 'bun:test';
import { buildAliasMoveReport } from './build-alias-move-report.ts';
import type { AliasMoveReport, AliasVerdict } from './types.ts';

test.each<readonly [string, AliasVerdict, AliasMoveReport]>([
  [
    'reports a move',
    { kind: 'ok' },
    { outcome: 'moved', message: 'moved the agent alias to agent-abc1234\n' },
  ],
  [
    'warns on a skip',
    { kind: 'skip', reason: 'impd lacks the imageAliases feature' },
    {
      outcome: 'skipped',
      message:
        'warning: impd lacks the imageAliases feature, so the agent alias stays where it was and does not move to agent-abc1234\n',
    },
  ],
  [
    'names the failed move and the pinned image on a failure',
    { kind: 'fail', reason: 'impz image alias timed out' },
    {
      outcome: 'failed',
      message:
        'could not move the agent alias to agent-abc1234; the image stays pinned: impz image alias timed out',
    },
  ],
])('it %s', (_title, verdict, expected) => {
  expect(buildAliasMoveReport(verdict, 'agent-abc1234')).toStrictEqual(expected);
});

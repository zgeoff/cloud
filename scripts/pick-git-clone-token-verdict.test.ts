import { expect, test } from 'bun:test';
import { pickGitCloneTokenVerdict } from './pick-git-clone-token-verdict.ts';

test.each([
  { exitCode: 0, verdict: 'good' },
  { exitCode: 120, verdict: 'absent' },
  { exitCode: 121, verdict: 'bad' },
  { exitCode: 122, verdict: 'bad' },
  { exitCode: 1, verdict: 'unchecked' },
  { exitCode: 255, verdict: 'unchecked' },
])('it picks $verdict for the host check exit $exitCode', (row) => {
  expect(pickGitCloneTokenVerdict(row.exitCode)).toBe(row.verdict);
});

import type { AliasVerdict, ImpAnswer } from './types.ts';

// Reads the answer of `impz image alias`. It runs only on an impd that reports the imageAliases
// feature, so every failure fails the move, an unknown command included.
export function pickAliasVerdictForMove(move: Readonly<ImpAnswer>): AliasVerdict {
  if (move.timedOut) {
    return { kind: 'fail', reason: 'impz image alias timed out' };
  }

  if (move.exitCode === 0) {
    return { kind: 'ok' };
  }

  return {
    kind: 'fail',
    reason: `impz image alias exited ${move.exitCode}: ${move.stderr.trim()}`,
  };
}

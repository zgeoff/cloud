import type { AliasVerdict, ImpAnswer } from './types.ts';

// impz exits 2 for a usage error, such as a command it does not know
const impUsageExitCode = 2;

// Reads the answer of `impz image alias`. Only an impz that exits with its usage error for an
// unknown command skips the move: a timeout or any other failure fails it.
export function pickAliasVerdictForMove(move: Readonly<ImpAnswer>): AliasVerdict {
  if (move.timedOut) {
    return { kind: 'fail', reason: 'impz image alias timed out' };
  }

  if (move.exitCode === 0) {
    return { kind: 'ok' };
  }

  const stderr = move.stderr.trim();

  if (move.exitCode === impUsageExitCode && /unknown command/iu.test(stderr)) {
    return { kind: 'skip', reason: 'impz does not know image alias' };
  }

  return { kind: 'fail', reason: `impz image alias exited ${move.exitCode}: ${stderr}` };
}

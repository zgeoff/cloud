import { expect, test } from 'bun:test';
import { pickAliasVerdictForMove } from './pick-alias-verdict-for-move.ts';
import type { AliasVerdict, ImpAnswer } from './types.ts';

test.each<readonly [string, ImpAnswer, AliasVerdict]>([
  ['is moved', { exitCode: 0, timedOut: false, stdout: '', stderr: '' }, { kind: 'ok' }],
  [
    'is an unknown command that exits 2',
    {
      exitCode: 2,
      timedOut: false,
      stdout: '',
      stderr: 'impz: unknown command image alias (see impz --help)\n',
    },
    { kind: 'skip', reason: 'impz does not know image alias' },
  ],
  [
    'is an unknown command that exits 1',
    { exitCode: 1, timedOut: false, stdout: '', stderr: 'impz: unknown command image alias\n' },
    { kind: 'fail', reason: 'impz image alias exited 1: impz: unknown command image alias' },
  ],
  [
    'is an unknown command after a timeout',
    { exitCode: 2, timedOut: true, stdout: '', stderr: 'impz: unknown command image alias\n' },
    { kind: 'fail', reason: 'impz image alias timed out' },
  ],
  [
    'is a usage error that names no unknown command',
    {
      exitCode: 2,
      timedOut: false,
      stdout: '',
      stderr: 'impz: usage: image alias <alias> <image>\n',
    },
    { kind: 'fail', reason: 'impz image alias exited 2: impz: usage: image alias <alias> <image>' },
  ],
  [
    'is a conflict',
    { exitCode: 1, timedOut: false, stdout: '', stderr: 'impz: CONFLICT: alias is reserved\n' },
    { kind: 'fail', reason: 'impz image alias exited 1: impz: CONFLICT: alias is reserved' },
  ],
])('it reads a move that %s', (_title, move, expected) => {
  expect(pickAliasVerdictForMove(move)).toStrictEqual(expected);
});

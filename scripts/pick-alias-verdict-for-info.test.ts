import { expect, test } from 'bun:test';
import { pickAliasVerdictForInfo } from './pick-alias-verdict-for-info.ts';
import type { AliasVerdict, ImpAnswer } from './types.ts';

test.each<readonly [string, ImpAnswer, AliasVerdict]>([
  [
    'goes on when impd reports the feature',
    { exitCode: 0, timedOut: false, stdout: '{"features":{"imageAliases":true}}\n', stderr: '' },
    { kind: 'ok' },
  ],
  [
    'skips when impd lists the features without it',
    { exitCode: 0, timedOut: false, stdout: '{"features":{"imageAliases":false}}\n', stderr: '' },
    { kind: 'skip', reason: 'impd lacks the imageAliases feature' },
  ],
  [
    'skips when impd lists no such feature',
    { exitCode: 0, timedOut: false, stdout: '{"features":{}}\n', stderr: '' },
    { kind: 'skip', reason: 'impd lacks the imageAliases feature' },
  ],
  [
    'fails on an unknown command, whatever its exit code',
    { exitCode: 2, timedOut: false, stdout: '', stderr: 'impz: unknown command inspect\n' },
    { kind: 'fail', reason: 'impz info exited 2: impz: unknown command inspect' },
  ],
  [
    'fails on an exit 0 with an error message and no JSON',
    { exitCode: 0, timedOut: false, stdout: '', stderr: 'impz: unknown command inspect\n' },
    { kind: 'fail', reason: 'impz info printed no feature list' },
  ],
  [
    'fails on a timeout',
    { exitCode: 124, timedOut: true, stdout: '', stderr: '' },
    { kind: 'fail', reason: 'impz info timed out' },
  ],
  [
    'fails on JSON without a feature list',
    { exitCode: 0, timedOut: false, stdout: '{"version":"1"}\n', stderr: '' },
    { kind: 'fail', reason: 'impz info printed no feature list' },
  ],
])('it reads an info answer that %s', (_title, info, expected) => {
  expect(pickAliasVerdictForInfo(info)).toStrictEqual(expected);
});

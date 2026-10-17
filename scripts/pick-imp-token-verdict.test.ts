import { expect, test } from 'bun:test';
import type { ImpTokenCheck } from './pick-imp-token-verdict.ts';
import { pickImpTokenVerdict } from './pick-imp-token-verdict.ts';

test.each([
  ['the file atc cannot use, exit 121', { exitCode: 121, stdout: '' }, 'bad'],
  [
    'the file it cannot read, exit 120',
    { exitCode: 120, stdout: '' },
    'the saved token is not a readable regular file on the host',
  ],
  ['the token impd refuses, exit 122', { exitCode: 122, stdout: '' }, 'bad'],
  [
    'the CLI’s exit 1',
    { exitCode: 1, stdout: '' },
    "the check on the host exited 1 (imp's CLI's exit code, or 255 from ssh)",
  ],
  [
    'ssh’s exit 255',
    { exitCode: 255, stdout: '' },
    "the check on the host exited 255 (imp's CLI's exit code, or 255 from ssh)",
  ],
  [
    'atc-cloud’s identity',
    { exitCode: 0, stdout: '{"kind":"token","name":"atc-cloud","scope":"manage"}\n' },
    'good',
  ],
  [
    'atc-cloud’s identity spaced over lines',
    { exitCode: 0, stdout: '{\n  "kind": "token",\n  "name": "atc-cloud"\n}\n' },
    'good',
  ],
  ['another token', { exitCode: 0, stdout: '{"kind":"token","name":"atc-other"}\n' }, 'bad'],
  [
    'a caller other than a token',
    { exitCode: 0, stdout: '{"kind":"user","name":"atc-cloud"}\n' },
    'bad',
  ],
  ['an empty answer', { exitCode: 0, stdout: '' }, 'impd answered without an identity'],
  [
    'an answer that is not JSON',
    { exitCode: 0, stdout: 'token atc-cloud (manage)\n' },
    'impd answered without an identity',
  ],
  [
    'an identity that lacks a name',
    { exitCode: 0, stdout: '{"kind":"token"}\n' },
    'impd answered without an identity',
  ],
])('it reads %s', (_label: string, check: ImpTokenCheck, verdict: string) => {
  expect(pickImpTokenVerdict(check)).toBe(verdict);
});

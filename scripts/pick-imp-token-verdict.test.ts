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
  [
    'curl’s exit 7',
    { exitCode: 7, stdout: '\n000' },
    "the check on the host exited 7 (curl's exit code, or 255 from ssh)",
  ],
  [
    'ssh’s exit 255',
    { exitCode: 255, stdout: '' },
    "the check on the host exited 255 (curl's exit code, or 255 from ssh)",
  ],
  ['impd’s 401', { exitCode: 0, stdout: '{"error":"unauthorized"}\n401' }, 'bad'],
  [
    'atc-cloud’s identity',
    { exitCode: 0, stdout: '{"json":{"kind":"token","name":"atc-cloud","scope":"manage"}}\n200' },
    'good',
  ],
  [
    'atc-cloud’s identity with a 2xx other than 200',
    { exitCode: 0, stdout: '{"json":{"kind":"token","name":"atc-cloud"}}\n203' },
    'good',
  ],
  [
    'another token',
    { exitCode: 0, stdout: '{"json":{"kind":"token","name":"atc-other"}}\n200' },
    'bad',
  ],
  [
    'a caller other than a token',
    { exitCode: 0, stdout: '{"json":{"kind":"user","name":"atc-cloud"}}\n200' },
    'bad',
  ],
  [
    'a 204 without a body',
    { exitCode: 0, stdout: '\n204' },
    'impd answered HTTP 204 without an identity',
  ],
  [
    'a 200 with a body that is not JSON',
    { exitCode: 0, stdout: '<html>ok</html>\n200' },
    'impd answered HTTP 200 without an identity',
  ],
  [
    'a 200 whose identity lacks a name',
    { exitCode: 0, stdout: '{"json":{"kind":"token"}}\n200' },
    'impd answered HTTP 200 without an identity',
  ],
  [
    'a 500',
    { exitCode: 0, stdout: '{"json":{"code":"INTERNAL_SERVER_ERROR"}}\n500' },
    'impd answered HTTP 500',
  ],
  [
    'a 403',
    { exitCode: 0, stdout: '{"json":{"code":"FORBIDDEN"}}\n403' },
    'impd answered HTTP 403',
  ],
])('it reads %s', (_label: string, check: ImpTokenCheck, verdict: string) => {
  expect(pickImpTokenVerdict(check)).toBe(verdict);
});

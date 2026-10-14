import { expect, test } from 'bun:test';
import { parseJSONOutput } from './parse-json-output.ts';

test('it parses a tool’s JSON answer', () => {
  expect(parseJSONOutput('{"features":{"grantableTokens":true}}\n', 'imp info')).toStrictEqual({
    features: { grantableTokens: true },
  });
});

test('it stops with exit 1 and names the source of an answer that is not JSON', () => {
  expect(() => parseJSONOutput('Error: not logged in', 'op item list')).toThrow(
    expect.objectContaining({ exitCode: 1, message: 'no JSON from op item list' }),
  );
});

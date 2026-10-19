import { expect, test } from 'bun:test';
import { parseTimeoutDuration } from './parse-timeout-duration.ts';

test.each([
  ['45m', 2_700_000],
  ['1s', 1000],
  ['30', 30_000],
  ['1.5h', 5_400_000],
  ['2d', 172_800_000],
])('it reads %s as %d milliseconds', (text, expectedMs) => {
  expect(parseTimeoutDuration(text, 'AGENT_IMAGE_BUILD_TIMEOUT')).toBe(expectedMs);
});

test.each([['0'], ['0s'], ['45 m'], ['45min'], ['-1s'], ['']])('it refuses %p', (text) => {
  expect(() => parseTimeoutDuration(text, 'AGENT_IMAGE_BUILD_TIMEOUT')).toThrow(
    expect.objectContaining({
      exitCode: 2,
      message: `AGENT_IMAGE_BUILD_TIMEOUT holds '${text}', not a duration such as 45m`,
    }),
  );
});

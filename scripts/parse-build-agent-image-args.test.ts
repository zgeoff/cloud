import { expect, test } from 'bun:test';
import { parseBuildAgentImageArgs } from './parse-build-agent-image-args.ts';

test('it builds origin/main’s head without --keep by default', () => {
  expect(parseBuildAgentImageArgs([], '45m')).toStrictEqual({
    keep: false,
    commit: 'origin/main',
    timeout: '45m',
    timeoutMs: 2_700_000,
  });
});

test('it reads --keep and a commit', () => {
  expect(parseBuildAgentImageArgs(['--keep', 'abc1234'], '1s')).toStrictEqual({
    keep: true,
    commit: 'abc1234',
    timeout: '1s',
    timeoutMs: 1000,
  });
});

test.each([
  ['an option other than --keep', ['--switch']],
  ['an empty commit', ['']],
  ['a second commit', ['abc1234', 'def5678']],
  ['a second --keep', ['--keep', '--keep']],
] as const)('it refuses %s with its usage', (_label, args) => {
  expect(() => parseBuildAgentImageArgs(args, '45m')).toThrow(
    expect.objectContaining({
      exitCode: 2,
      message: 'usage: build-agent-image.ts [--keep] [<commit on main>]',
    }),
  );
});

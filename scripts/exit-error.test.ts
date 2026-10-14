import { expect, test } from 'bun:test';
import { ExitError } from './exit-error.ts';

test('it carries the exit code and the message', () => {
  const error = new ExitError(2, 'usage: switch-agent-image.ts <image>');

  expect(error).toBeInstanceOf(Error);

  expect(error).toMatchObject({
    name: 'ExitError',
    exitCode: 2,
    message: 'usage: switch-agent-image.ts <image>',
  });
});

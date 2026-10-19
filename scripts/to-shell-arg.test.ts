import { expect, test } from 'bun:test';
import { toShellArg } from './to-shell-arg.ts';

test('it passes a command with quotes, a dollar sign and a redirect through bash as one word', async () => {
  const command = `echo 'a "b"' $HOME 2>/dev/null; echo done`;

  const subprocess = Bun.spawn(['bash', '-c', `printf '%s' ${toShellArg(command)}`], {
    env: { PATH: '/usr/bin:/bin' },
    stdout: 'pipe',
  });

  const stdout = await new Response(subprocess.stdout).text();

  expect(stdout).toBe(command);
});

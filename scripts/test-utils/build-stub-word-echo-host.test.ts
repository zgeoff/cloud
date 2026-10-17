import { expect, test } from 'bun:test';
import { buildStubRunner } from './build-stub-runner.ts';
import { buildStubWordEchoHost } from './build-stub-word-echo-host.ts';

test('it prints each word that a shell parses from the remote line, unquoted words split on spaces', async () => {
  const stub = buildStubRunner(buildStubWordEchoHost());

  const result = await stub.run(['ssh', 'root@geoffcloud', String.raw`a 'b c' 'it'\''s' d\ e`]);

  expect(result.stdout.toString()).toBe("[a]\n[b c]\n[it's]\n[d e]\n");
});

test('it expands an unquoted variable as the host’s shell would, with an empty environment', async () => {
  const stub = buildStubRunner(buildStubWordEchoHost());

  const result = await stub.run(['ssh', 'root@geoffcloud', 'x $HOME y']);

  expect(result.stdout.toString()).toBe('[x]\n[y]\n');
});

test('it leaves a call that is not ssh to the next handler', async () => {
  const stub = buildStubRunner(buildStubWordEchoHost());

  const result = await stub.run(['scp', 'a', 'b']);

  expect(result.exitCode).toBe(97);
});

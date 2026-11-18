import { expect, test } from 'bun:test';
import { buildStubATCKey } from './build-stub-atc-key.ts';
import { buildStubRunner } from './build-stub-runner.ts';

test('it prints the z.ai key and a newline, as atc-key’s printf does', async () => {
  const stub = buildStubRunner(buildStubATCKey({ installed: true, zaiKey: 'zai_fixture_key' }));

  const found = await stub.run(['sh', '-c', 'command -v atc-key > /dev/null']);
  const key = await stub.run(['atc-key', 'zai']);

  expect(found.exitCode).toBe(0);
  expect(key.stdout.toString()).toBe('zai_fixture_key\n');
});

test('it is not found, and never answers, when it is not installed', async () => {
  const stub = buildStubRunner(buildStubATCKey({ installed: false, zaiKey: 'zai_fixture_key' }));

  const found = await stub.run(['sh', '-c', 'command -v atc-key > /dev/null']);
  const key = await stub.run(['atc-key', 'zai']);

  expect(found.exitCode).toBe(1);
  expect(key.exitCode).toBe(97);
});

test('it leaves another provider to the next handler', async () => {
  const stub = buildStubRunner(buildStubATCKey({ installed: true, zaiKey: 'zai_fixture_key' }));

  const result = await stub.run(['atc-key', 'kimi']);

  expect(result.exitCode).toBe(97);
});

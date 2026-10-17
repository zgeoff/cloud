import { expect, test } from 'bun:test';
import { buildMockCredentialsHostScenario } from './build-mock-credentials-host-scenario.ts';
import { buildStubCredentialTools } from './build-stub-credential-tools.ts';

test('it answers op, atc-key and ssh to the host from one runner, and records every call', async () => {
  const tools = buildStubCredentialTools({
    op: { vaults: { cloud: {} } },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario(),
  });

  const vault = await tools.run(['op', 'vault', 'get', 'cloud', '--format', 'json']);
  const key = await tools.run(['atc-key', 'zai']);

  const host = await tools.run([
    'ssh',
    '-o',
    'BatchMode=yes',
    '-o',
    'ConnectTimeout=15',
    'root@geoffcloud',
    "'true'",
  ]);

  expect(vault.exitCode).toBe(0);
  expect(key.stdout.toString()).toBe('zai_fixture_key\n');
  expect(host.exitCode).toBe(0);
  expect(tools.calls.map((call) => call.argv[0])).toStrictEqual(['op', 'atc-key', 'ssh']);
});

test('it fails any other program with exit 97', async () => {
  const tools = buildStubCredentialTools({
    op: { vaults: {} },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario(),
  });

  const result = await tools.run(['curl', 'https://example.com']);

  expect(result.exitCode).toBe(97);
});

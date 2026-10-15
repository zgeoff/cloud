import { expect, test } from 'bun:test';
import { readImpList } from './read-imp-list.ts';
import { buildMockCredentialsHostScenario } from './test-utils/build-mock-credentials-host-scenario.ts';
import { buildStubCredentialsHost } from './test-utils/build-stub-credentials-host.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';

test('it reads impd’s tokens through the impz CLI in imp-host', async () => {
  const host = buildMockCredentialsHostScenario();
  const stub = buildStubRunner(buildStubCredentialsHost(host).handle);

  const tokens = await readImpList(
    { run: stub.run, printOut: () => {}, printErr: () => {}, host: 'root@geoffcloud' },
    'token',
  );

  expect(tokens).toStrictEqual(host.tokens);

  expect(stub.calls.map((call) => call.argv)).toStrictEqual([
    [
      'ssh',
      '-o',
      'BatchMode=yes',
      'root@geoffcloud',
      'docker',
      'exec',
      'imp-host',
      'impz',
      'token',
      'ls',
      '--json',
    ],
  ]);
});

test('it stops with docker’s exit code when imp-host is stopped', () => {
  const stub = buildStubRunner(
    buildStubCredentialsHost(buildMockCredentialsHostScenario({ stoppedAt: 'secret-ls' })).handle,
  );

  expect(
    readImpList(
      { run: stub.run, printOut: () => {}, printErr: () => {}, host: 'root@geoffcloud' },
      'secret',
    ),
  ).rejects.toMatchObject({ exitCode: 1 });
});

test('it stops when imp prints something other than JSON', () => {
  const stub = buildStubRunner(() => ({ stdout: 'imp: unknown command\n' }));

  expect(
    readImpList(
      { run: stub.run, printOut: () => {}, printErr: () => {}, host: 'root@geoffcloud' },
      'secret',
    ),
  ).rejects.toMatchObject({ exitCode: 1, message: 'no JSON from impz secret ls' });
});

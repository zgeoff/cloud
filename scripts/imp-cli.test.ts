import { expect, test } from 'bun:test';
import {
  buildHostImpArgv,
  buildImpArgv,
  formatImpCommand,
  loadHostImpJSON,
  loadImpJSON,
} from './imp-cli.ts';
import { buildMockCredentialsHostScenario } from './test-utils/build-mock-credentials-host-scenario.ts';
import { buildStubCredentialsHost } from './test-utils/build-stub-credentials-host.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';

test('#buildImpArgv puts imp’s CLI before the arguments', () => {
  expect(buildImpArgv(['image', 'rm', 'agent-abc1234'])).toStrictEqual([
    'impz',
    'image',
    'rm',
    'agent-abc1234',
  ]);
});

test('#buildHostImpArgv runs the CLI in imp-host without -i when the call reads no stdin', () => {
  expect(buildHostImpArgv(['token', 'ls'])).toStrictEqual([
    'docker',
    'exec',
    'imp-host',
    'impz',
    'token',
    'ls',
  ]);
});

test('#buildHostImpArgv passes docker -i when the call reads stdin', () => {
  expect(buildHostImpArgv(['secret', 'add', 'glm'], { stdin: true })).toStrictEqual([
    'docker',
    'exec',
    '-i',
    'imp-host',
    'impz',
    'secret',
    'add',
    'glm',
  ]);
});

test('#buildHostImpArgv passes each env name to docker without a value, so docker copies its own', () => {
  expect(
    buildHostImpArgv(['token', 'whoami', '--json'], { env: ['IMP_TOKEN', 'IMP_URL'] }),
  ).toStrictEqual([
    'docker',
    'exec',
    '-e',
    'IMP_TOKEN',
    '-e',
    'IMP_URL',
    'imp-host',
    'impz',
    'token',
    'whoami',
    '--json',
  ]);
});

test('#formatImpCommand writes the call as a person types it', () => {
  expect(formatImpCommand(['token', 'rm', 'atc-cloud'])).toBe('impz token rm atc-cloud');
});

test('#loadImpJSON parses the answer of the call it runs with --json', async () => {
  const stub = buildStubRunner(() => ({ stdout: '[{"name":"agent-check-abc1234"}]\n' }));

  const list = await loadImpJSON({ run: stub.run, printOut: () => {}, printErr: () => {} }, ['ls']);

  expect(list).toStrictEqual([{ name: 'agent-check-abc1234' }]);
  expect(stub.calls.map((call) => call.argv)).toStrictEqual([['impz', 'ls', '--json']]);
});

test('#loadImpJSON stops when imp prints no JSON, naming the call without --json', () => {
  const stub = buildStubRunner(() => ({ stdout: 'NAME  IMAGE\n' }));

  expect(
    loadImpJSON({ run: stub.run, printOut: () => {}, printErr: () => {} }, ['image', 'ls']),
  ).rejects.toMatchObject({ exitCode: 1, message: 'no JSON from impz image ls' });
});

test('#loadImpJSON stops with imp’s exit code when the call fails', () => {
  const stub = buildStubRunner(() => ({ exitCode: 4, stderr: 'imp: UNAUTHORIZED\n' }));

  expect(
    loadImpJSON({ run: stub.run, printOut: () => {}, printErr: () => {} }, ['ls']),
  ).rejects.toMatchObject({ exitCode: 4 });
});

test('#loadHostImpJSON reads impd’s tokens through the CLI in imp-host over ssh as root', async () => {
  const host = buildMockCredentialsHostScenario();
  const stub = buildStubRunner(buildStubCredentialsHost(host).answer);

  const tokens = await loadHostImpJSON(
    { run: stub.run, printOut: () => {}, printErr: () => {}, host: 'geoffcloud' },
    ['token', 'ls'],
  );

  expect(tokens).toStrictEqual(host.tokens);

  expect(stub.calls).toStrictEqual([
    {
      argv: [
        'ssh',
        '-o',
        'BatchMode=yes',
        '-o',
        'ConnectTimeout=15',
        'root@geoffcloud',
        "'docker' 'exec' 'imp-host' 'impz' 'token' 'ls' '--json'",
      ],
      stdin: '',
      options: { timeoutMs: 120_000 },
    },
  ]);
});

test('#loadHostImpJSON stops with docker’s exit code when imp-host is stopped', () => {
  const stub = buildStubRunner(
    buildStubCredentialsHost(buildMockCredentialsHostScenario({ stoppedAt: 'secret-ls' })).answer,
  );

  expect(
    loadHostImpJSON({ run: stub.run, printOut: () => {}, printErr: () => {}, host: 'geoffcloud' }, [
      'secret',
      'ls',
    ]),
  ).rejects.toMatchObject({ exitCode: 1 });
});

test('#loadHostImpJSON stops when imp prints something other than JSON, naming the call without --json', () => {
  const stub = buildStubRunner(() => ({ stdout: 'imp: unknown command\n' }));

  expect(
    loadHostImpJSON({ run: stub.run, printOut: () => {}, printErr: () => {}, host: 'geoffcloud' }, [
      'secret',
      'ls',
    ]),
  ).rejects.toMatchObject({ exitCode: 1, message: 'no JSON from impz secret ls' });
});

test('#loadHostImpJSON sends its stdin to the CLI through docker exec -i', async () => {
  const host = buildStubCredentialsHost(buildMockCredentialsHostScenario({ secrets: [] }));
  const stub = buildStubRunner(host.answer);

  await loadHostImpJSON(
    { run: stub.run, printOut: () => {}, printErr: () => {}, host: 'geoffcloud' },
    [
      'secret',
      'add',
      'glm',
      '--kind',
      'custom',
      '--hosts',
      'api.z.ai',
      '--header',
      'authorization',
      '--scheme',
      'bearer',
    ],
    Buffer.from('zai_fixture_key\n'),
  );

  expect(host.secretValues).toStrictEqual({ glm: 'zai_fixture_key' });

  expect(stub.calls).toStrictEqual([
    {
      argv: [
        'ssh',
        '-o',
        'BatchMode=yes',
        '-o',
        'ConnectTimeout=15',
        'root@geoffcloud',
        "'docker' 'exec' '-i' 'imp-host' 'impz' 'secret' 'add' 'glm' '--kind' 'custom' '--hosts' 'api.z.ai' '--header' 'authorization' '--scheme' 'bearer' '--json'",
      ],
      stdin: 'zai_fixture_key\n',
      options: { timeoutMs: 120_000 },
    },
  ]);
});

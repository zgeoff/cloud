import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runProcess } from '../run-process.ts';
import { createStubImpDocker } from './create-stub-imp-docker.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'create-stub-imp-docker-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  return { directory };
}

test('it answers the atc-cloud mint as the scenario says, and logs the call', async () => {
  const ctx = await setupTest();

  const docker = await createStubImpDocker(ctx.directory, {
    stdout: 'imp_fixture_minted_token\n',
    stderr: 'impz: token atc-cloud made; impd shows its secret only this once\n',
    exitCode: 0,
  });

  const result = await runProcess([
    docker,
    'exec',
    'imp-host',
    'impz',
    'token',
    'new',
    'atc-cloud',
    '--scope',
    'manage',
    '--imps',
    'harness-*',
    '--grantable',
    'glm,claude-setup-token,github-imp-agents,linear-imp-agents,op-connect',
  ]);

  expect(result).toStrictEqual({
    exitCode: 0,
    stdout: Buffer.from('imp_fixture_minted_token\n'),
    stderr: Buffer.from('impz: token atc-cloud made; impd shows its secret only this once\n'),
    timedOut: false,
  });

  const calls = await readFile(join(ctx.directory, 'docker-calls'), 'utf8');

  expect(calls).toBe(
    '["docker","exec","imp-host","impz","token","new","atc-cloud","--scope","manage","--imps","harness-*","--grantable","glm,claude-setup-token,github-imp-agents,linear-imp-agents,op-connect"]\n',
  );
});

test('it ends any other call with exit 97', async () => {
  const ctx = await setupTest();
  const docker = await createStubImpDocker(ctx.directory, { stdout: '', stderr: '', exitCode: 0 });
  const result = await runProcess([docker, 'exec', 'imp-host', 'impz', 'token', 'rm', 'atc-cloud']);

  expect(result.exitCode).toBe(97);
  expect(result.stderr.toString()).toBe('unexpected: exec imp-host impz token rm atc-cloud\n');
});

test('it answers the call it is given, and logs the IMP_TOKEN and IMP_URL it got', async () => {
  const ctx = await setupTest();

  const docker = await createStubImpDocker(
    ctx.directory,
    { stdout: '{"kind":"token","name":"atc-cloud"}\n', stderr: '', exitCode: 0 },
    ['exec', '-e', 'IMP_TOKEN', '-e', 'IMP_URL', 'imp-host', 'impz', 'token', 'whoami', '--json'],
  );

  const result = await runProcess(
    [
      docker,
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
    ],
    {
      env: {
        PATH: process.env['PATH'] ?? '/usr/bin:/bin',
        IMP_TOKEN: 'imp_fixture_good',
        IMP_URL: 'http://127.0.0.1:7070',
      },
    },
  );

  const env = await readFile(join(ctx.directory, 'docker-env'), 'utf8');

  expect(result.stdout.toString()).toBe('{"kind":"token","name":"atc-cloud"}\n');
  expect(env).toBe('{"IMP_TOKEN":"imp_fixture_good","IMP_URL":"http://127.0.0.1:7070"}\n');
});

test('it logs an unset IMP_TOKEN and IMP_URL as null', async () => {
  const ctx = await setupTest();
  const docker = await createStubImpDocker(ctx.directory, { stdout: '', stderr: '', exitCode: 0 });

  await runProcess([docker, 'exec', 'imp-host', 'impz', 'token', 'rm', 'atc-cloud'], {
    env: { PATH: process.env['PATH'] ?? '/usr/bin:/bin' },
  });

  const env = await readFile(join(ctx.directory, 'docker-env'), 'utf8');

  expect(env).toBe('{"IMP_TOKEN":null,"IMP_URL":null}\n');
});

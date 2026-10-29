import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readHostScript } from '../read-host-script.ts';
import { runProcess } from '../run-process.ts';
import { toShellArg } from '../to-shell-arg.ts';
import { buildMockCredentialsHostScenario } from './build-mock-credentials-host-scenario.ts';
import { buildMockImpSecret } from './build-mock-imp-secret.ts';
import { buildStubCredentialsHost } from './build-stub-credentials-host.ts';
import { buildStubRunner } from './build-stub-runner.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'build-stub-credentials-host-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  return { directory, env: { PATH: process.env['PATH'] ?? '/usr/bin:/bin', HOME: directory } };
}

test('it saves the bearer as the real write script does', async () => {
  const ctx = await setupTest();
  const script = await readHostScript('write-atc-gateway-token.sh');

  const stdin = Buffer.concat([script, Buffer.from('fixture-bearer\n')]);

  const host = buildStubCredentialsHost(
    buildMockCredentialsHostScenario({ directory: ctx.directory, files: {} }),
  );

  const stub = buildStubRunner(host.answer);

  await stub.run(
    [
      'ssh',
      '-o',
      'BatchMode=yes',
      '-o',
      'ConnectTimeout=15',
      'root@geoffcloud',
      `'bash' '-s' '--' ${toShellArg(ctx.directory)}`,
    ],
    { stdin },
  );

  await runProcess(['bash', '-s', '--', ctx.directory], { stdin, env: ctx.env });

  const real = await readFile(join(ctx.directory, 'gateway-token'), 'utf8');

  expect(host.files['gateway-token']).toStrictEqual({ content: real, mode: '400' });
});

test('it exits 120 for a missing saved token, as the real check script does', async () => {
  const ctx = await setupTest();
  const script = await readHostScript('check-atc-imp-token.sh');

  const host = buildStubCredentialsHost(
    buildMockCredentialsHostScenario({ directory: ctx.directory, files: {} }),
  );

  const stub = buildStubRunner(host.answer);

  const modelled = await stub.run(
    [
      'ssh',
      '-o',
      'BatchMode=yes',
      '-o',
      'ConnectTimeout=15',
      'root@geoffcloud',
      `'bash' '-s' '--' ${toShellArg(ctx.directory)} '7070' 'podman' 'exec' '-e' 'IMP_TOKEN' '-e' 'IMP_URL' 'imp-host' 'impz'`,
    ],
    { stdin: script },
  );

  const cli = ['podman', 'exec', '-e', 'IMP_TOKEN', '-e', 'IMP_URL', 'imp-host', 'impz'];

  const real = await runProcess(['bash', '-s', '--', ctx.directory, '7070', ...cli], {
    stdin: script,
    env: ctx.env,
  });

  expect(modelled.exitCode).toBe(120);
  expect(real.exitCode).toBe(120);
});

test('it adds glm from the line on stdin and prints it with droppedGrants, as impz secret add does', async () => {
  const host = buildStubCredentialsHost(buildMockCredentialsHostScenario({ secrets: [] }));
  const stub = buildStubRunner(host.answer);

  const result = await stub.run(
    [
      'ssh',
      '-o',
      'BatchMode=yes',
      '-o',
      'ConnectTimeout=15',
      'root@geoffcloud',
      "'podman' 'exec' '-i' 'imp-host' 'impz' 'secret' 'add' 'glm' '--kind' 'custom' '--hosts' 'api.z.ai' '--header' 'authorization' '--scheme' 'bearer' '--json'",
    ],
    { stdin: Buffer.from('zai_fixture_key\n') },
  );

  expect(host.secretValues).toStrictEqual({ glm: 'zai_fixture_key' });

  expect(JSON.parse(result.stdout.toString())).toStrictEqual({
    name: 'glm',
    kind: 'static',
    rules: [{ host: 'api.z.ai', header: 'authorization', scheme: 'bearer' }],
    env: [],
    imps: [],
    createdAt: '2026-10-07T12:00:00.000Z',
    droppedGrants: 0,
  });
});

test('it mints atc-cloud into imp-token and impd’s tokens, with imp’s notice on stderr', async () => {
  const script = await readHostScript('mint-atc-imp-token.sh');

  const scenario = buildMockCredentialsHostScenario({
    tokens: [],
    files: {},
    minted: 'imp_fixture_minted_token\n',
  });

  const stub = buildStubRunner(buildStubCredentialsHost(scenario).answer);

  const result = await stub.run(
    [
      'ssh',
      '-o',
      'BatchMode=yes',
      '-o',
      'ConnectTimeout=15',
      'root@geoffcloud',
      "'bash' '-s' '--' '/var/lib/atc-daemon-secrets' 'podman' 'exec' 'imp-host' 'impz'",
    ],
    { stdin: script },
  );

  expect(result.stderr.toString()).toBe(
    'impz: token atc-cloud made; impd shows its secret only this once\n',
  );

  expect(scenario.files).toStrictEqual({
    'imp-token': { content: 'imp_fixture_minted_token\n', mode: '400' },
  });

  expect(scenario.tokens).toPartiallyContain({
    name: 'atc-cloud',
    scope: 'manage',
    grantable: [
      'claude-setup-token',
      'github-imp-agents',
      'glm',
      'linear-imp-agents',
      'op-connect',
    ],
  });
});

test('it fails the mint as impd does, writing no file, when a secret atc-cloud may grant is missing', async () => {
  const script = await readHostScript('mint-atc-imp-token.sh');

  const scenario = buildMockCredentialsHostScenario({
    secrets: [{ ...buildMockImpSecret() }],
    tokens: [],
    files: {},
  });

  const stub = buildStubRunner(buildStubCredentialsHost(scenario).answer);

  const result = await stub.run(
    [
      'ssh',
      '-o',
      'BatchMode=yes',
      '-o',
      'ConnectTimeout=15',
      'root@geoffcloud',
      "'bash' '-s' '--' '/var/lib/atc-daemon-secrets' 'podman' 'exec' 'imp-host' 'impz'",
    ],
    { stdin: script },
  );

  expect(result.exitCode).toBe(1);
  expect(result.stderr.toString()).toBe('impz: NOT_FOUND: secret claude-setup-token not found\n');
  expect(scenario.files).toStrictEqual({});
  expect(scenario.tokens).toStrictEqual([]);
});

test('it fails podman exec as podman does when imp-host is stopped', async () => {
  const stub = buildStubRunner(
    buildStubCredentialsHost(buildMockCredentialsHostScenario({ stoppedAt: 'info' })).answer,
  );

  const result = await stub.run([
    'ssh',
    '-o',
    'BatchMode=yes',
    '-o',
    'ConnectTimeout=15',
    'root@geoffcloud',
    "'podman' 'exec' 'imp-host' 'impz' 'info' '--json'",
  ]);

  expect(result.exitCode).toBe(125);

  expect(result.stderr.toString()).toBe(
    'Error: no container with name or ID "imp-host" found: no such container\n',
  );
});

test('it stats the secrets directory and its files as stat -c prints them, and fails for a gone one', async () => {
  const stub = buildStubRunner(
    buildStubCredentialsHost(
      buildMockCredentialsHostScenario({
        files: { 'gateway-token': { content: 'fixture-bearer\n', mode: '400' } },
      }),
    ).answer,
  );

  const result = await stub.run([
    'ssh',
    '-o',
    'BatchMode=yes',
    '-o',
    'ConnectTimeout=15',
    'root@geoffcloud',
    "'stat' '-c' '%n %U %a %s bytes' '/var/lib/atc-daemon-secrets' '/var/lib/atc-daemon-secrets/gateway-token' '/var/lib/atc-daemon-secrets/imp-token'",
  ]);

  expect(result).toStrictEqual({
    exitCode: 1,
    stdout: Buffer.from(
      '/var/lib/atc-daemon-secrets root 700 4096 bytes\n/var/lib/atc-daemon-secrets/gateway-token root 400 15 bytes\n',
    ),
    stderr: Buffer.from(
      "stat: cannot statx '/var/lib/atc-daemon-secrets/imp-token': No such file or directory\n",
    ),
    timedOut: false,
  });
});

test('it refuses a call to another host, or without BatchMode', async () => {
  const stub = buildStubRunner(buildStubCredentialsHost(buildMockCredentialsHostScenario()).answer);

  const other = await stub.run([
    'ssh',
    '-o',
    'BatchMode=yes',
    '-o',
    'ConnectTimeout=15',
    'root@elsewhere',
    "'true'",
  ]);

  const interactive = await stub.run([
    'ssh',
    '-o',
    'ConnectTimeout=15',
    'root@geoffcloud',
    "'true'",
  ]);

  expect(other.exitCode).toBe(97);
  expect(interactive.exitCode).toBe(97);
});

test('it fails every call with ssh’s 255 when the host is unreachable', async () => {
  const stub = buildStubRunner(
    buildStubCredentialsHost(buildMockCredentialsHostScenario({ unreachable: true })).answer,
  );

  const result = await stub.run([
    'ssh',
    '-o',
    'BatchMode=yes',
    '-o',
    'ConnectTimeout=15',
    'root@geoffcloud',
    "'true'",
  ]);

  expect(result.exitCode).toBe(255);

  expect(result.stderr.toString()).toBe(
    'ssh: connect to host geoffcloud port 22: Connection refused\r\n',
  );
});

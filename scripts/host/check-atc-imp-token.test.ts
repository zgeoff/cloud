import { expect, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildHostImpArgv } from '../imp-cli.ts';
import { runProcess } from '../run-process.ts';
import { createStubImpDocker } from '../test-utils/create-stub-imp-docker.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'check-atc-imp-token-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const bin = join(directory, 'bin');
  const secrets = join(directory, 'secrets');

  await mkdir(bin);
  await mkdir(secrets);

  const script = await readFile(new URL('check-atc-imp-token.sh', import.meta.url));

  const env = { PATH: `${bin}:${process.env['PATH'] ?? '/usr/bin:/bin'}`, HOME: directory };
  const cli = buildHostImpArgv([], { env: ['IMP_TOKEN', 'IMP_URL'] });

  return { bin, secrets, script, env, cli };
}

test('it asks impd who the saved token is through the CLI, with the token in docker’s environment alone', async () => {
  const ctx = await setupTest();

  await createStubImpDocker(
    ctx.bin,
    { stdout: '{"kind":"token","name":"atc-cloud"}\n', stderr: '', exitCode: 0 },
    ['exec', '-e', 'IMP_TOKEN', '-e', 'IMP_URL', 'imp-host', 'impz', 'token', 'whoami', '--json'],
  );

  await writeFile(join(ctx.secrets, 'imp-token'), 'imp_fixture_good\n');

  const result = await runProcess(['bash', '-s', '--', ctx.secrets, '7070', ...ctx.cli], {
    stdin: ctx.script,
    env: ctx.env,
  });

  const calls = await readFile(join(ctx.bin, 'docker-calls'), 'utf8');
  const env = await readFile(join(ctx.bin, 'docker-env'), 'utf8');

  expect(result).toStrictEqual({
    exitCode: 0,
    stdout: Buffer.from('{"kind":"token","name":"atc-cloud"}\n'),
    stderr: Buffer.from(''),
    timedOut: false,
  });

  expect(calls).toBe(
    '["docker","exec","-e","IMP_TOKEN","-e","IMP_URL","imp-host","impz","token","whoami","--json"]\n',
  );

  expect(env).toBe('{"IMP_TOKEN":"imp_fixture_good","IMP_URL":"http://127.0.0.1:7070"}\n');
});

test('it hands on a saved token without a trailing newline as it is', async () => {
  const ctx = await setupTest();

  await createStubImpDocker(
    ctx.bin,
    { stdout: '{"kind":"token","name":"atc-cloud"}\n', stderr: '', exitCode: 0 },
    ['exec', '-e', 'IMP_TOKEN', '-e', 'IMP_URL', 'imp-host', 'impz', 'token', 'whoami', '--json'],
  );

  await writeFile(join(ctx.secrets, 'imp-token'), 'imp_fixture_good');

  await runProcess(['bash', '-s', '--', ctx.secrets, '7070', ...ctx.cli], {
    stdin: ctx.script,
    env: ctx.env,
  });

  const env = await readFile(join(ctx.bin, 'docker-env'), 'utf8');

  expect(env).toBe('{"IMP_TOKEN":"imp_fixture_good","IMP_URL":"http://127.0.0.1:7070"}\n');
});

// imp 2.4.1's CLI prints one line for impd's 401 when IMP_URL is set, and exits 1
// (packages/cli/src/run-action.ts)
test('it exits 122 with nothing printed for a token impd refuses', async () => {
  const ctx = await setupTest();

  await createStubImpDocker(
    ctx.bin,
    {
      stdout: '',
      stderr:
        'impz: unauthorized: set IMP_TOKEN to the token from <IMP_DATA_DIR>/token, or run impz login <url>\n',
      exitCode: 1,
    },
    ['exec', '-e', 'IMP_TOKEN', '-e', 'IMP_URL', 'imp-host', 'impz', 'token', 'whoami', '--json'],
  );

  await writeFile(join(ctx.secrets, 'imp-token'), 'imp_fixture_stale\n');

  const result = await runProcess(['bash', '-s', '--', ctx.secrets, '7070', ...ctx.cli], {
    stdin: ctx.script,
    env: ctx.env,
  });

  expect(result).toStrictEqual({
    exitCode: 122,
    stdout: Buffer.from(''),
    stderr: Buffer.from(''),
    timedOut: false,
  });
});

test('it exits with the CLI’s code and passes its line through for any other failure', async () => {
  const ctx = await setupTest();

  await createStubImpDocker(
    ctx.bin,
    {
      stdout: '',
      stderr: 'impz: Unable to connect. Is the computer able to access the url?\n',
      exitCode: 1,
    },
    ['exec', '-e', 'IMP_TOKEN', '-e', 'IMP_URL', 'imp-host', 'impz', 'token', 'whoami', '--json'],
  );

  await writeFile(join(ctx.secrets, 'imp-token'), 'imp_fixture_good\n');

  const result = await runProcess(['bash', '-s', '--', ctx.secrets, '1', ...ctx.cli], {
    stdin: ctx.script,
    env: ctx.env,
  });

  expect(result).toStrictEqual({
    exitCode: 1,
    stdout: Buffer.from(''),
    stderr: Buffer.from('impz: Unable to connect. Is the computer able to access the url?\n'),
    timedOut: false,
  });
});

test.each([
  ['an empty file', ''],
  ['a second line', 'imp_fixture_good\nsecond\n'],
  ['a blank line after the token', 'imp_fixture_good\n\n'],
  ['a carriage return', 'imp_fixture_good\r\n'],
  ['a space', 'imp_fixture good\n'],
  ['a NUL byte', 'imp_fixture\0good\n'],
])(
  'it exits 121 without asking impd for a saved token with %s',
  async (_label: string, content: string) => {
    const ctx = await setupTest();

    await createStubImpDocker(ctx.bin, { stdout: '', stderr: '', exitCode: 0 });
    await writeFile(join(ctx.secrets, 'imp-token'), content);

    const result = await runProcess(['bash', '-s', '--', ctx.secrets, '7070', ...ctx.cli], {
      stdin: ctx.script,
      env: ctx.env,
    });

    const called = await Bun.file(join(ctx.bin, 'docker-calls')).exists();

    expect(result.exitCode).toBe(121);
    expect(result.stdout.toString()).toBe('');
    expect(called).toBe(false);
  },
);

test.each([
  ['a missing file', false],
  ['a directory in its place', true],
])('it exits 120 without asking impd for %s', async (_label: string, directory: boolean) => {
  const ctx = await setupTest();

  await createStubImpDocker(ctx.bin, { stdout: '', stderr: '', exitCode: 0 });

  if (directory) {
    await mkdir(join(ctx.secrets, 'imp-token'));
  }

  const result = await runProcess(['bash', '-s', '--', ctx.secrets, '7070', ...ctx.cli], {
    stdin: ctx.script,
    env: ctx.env,
  });

  const called = await Bun.file(join(ctx.bin, 'docker-calls')).exists();

  expect(result.exitCode).toBe(120);
  expect(called).toBe(false);
});

test('it stops with a usage error when no CLI argv follows the port', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.secrets, 'imp-token'), 'imp_fixture_good\n');

  const result = await runProcess(['bash', '-s', '--', ctx.secrets, '7070'], {
    stdin: ctx.script,
    env: ctx.env,
  });

  expect({ exitCode: result.exitCode, stderr: result.stderr.toString() }).toStrictEqual({
    exitCode: 2,
    stderr: 'usage: check-atc-imp-token.sh <dir> <impd port> <imp CLI argv>...\n',
  });
});

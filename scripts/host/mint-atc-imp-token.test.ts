import { expect, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, readFile, readdir, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildHostImpArgv } from '../imp-cli.ts';
import { runProcess } from '../run-process.ts';
import { createStubImpDocker } from '../test-utils/create-stub-imp-docker.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'mint-atc-imp-token-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const bin = join(directory, 'bin');
  const secrets = join(directory, 'secrets');

  await mkdir(bin);
  await mkdir(secrets);

  const script = await readFile(new URL('mint-atc-imp-token.sh', import.meta.url));

  const env = { PATH: `${bin}:${process.env['PATH'] ?? '/usr/bin:/bin'}`, HOME: directory };

  return { bin, secrets, script, env };
}

test('it mints atc-cloud straight into a root-only imp-token in one rename', async () => {
  const ctx = await setupTest();

  await createStubImpDocker(ctx.bin, {
    stdout: 'imp_fixture_minted_token\n',
    stderr: 'impz: token atc-cloud made; impd shows its secret only this once\n',
    exitCode: 0,
  });

  const result = await runProcess(['bash', '-s', '--', ctx.secrets, ...buildHostImpArgv([])], {
    stdin: ctx.script,
    env: ctx.env,
  });

  const files = await readdir(ctx.secrets);
  const token = await readFile(join(ctx.secrets, 'imp-token'), 'utf8');
  const status = await stat(join(ctx.secrets, 'imp-token'));

  expect(result.exitCode).toBe(0);
  expect(files).toStrictEqual(['imp-token']);

  expect({ content: token, mode: (status.mode & 0o777).toString(8) }).toStrictEqual({
    content: 'imp_fixture_minted_token\n',
    mode: '400',
  });
});

test('it runs impz token new once with atc-cloud’s limits, and passes imp’s notice through', async () => {
  const ctx = await setupTest();

  await createStubImpDocker(ctx.bin, {
    stdout: 'imp_fixture_minted_token\n',
    stderr: 'impz: token atc-cloud made; impd shows its secret only this once\n',
    exitCode: 0,
  });

  const result = await runProcess(['bash', '-s', '--', ctx.secrets, ...buildHostImpArgv([])], {
    stdin: ctx.script,
    env: ctx.env,
  });

  const calls = await readFile(join(ctx.bin, 'docker-calls'), 'utf8');

  expect(result.stdout.toString()).toBe('');

  expect(result.stderr.toString()).toBe(
    'impz: token atc-cloud made; impd shows its secret only this once\n',
  );

  expect(calls).toBe(
    '["docker","exec","imp-host","impz","token","new","atc-cloud","--scope","manage","--imps","harness-*","--grantable","glm,claude-setup-token,github-imp-agents,linear-imp-agents,op-connect"]\n',
  );
});

test.each([
  ['the mint prints more than one line', 'imp_fixture_minted_token\nsecond line\n', 0],
  ['impz token new fails', '', 1],
])('it saves no token when %s', async (_label: string, stdout: string, exitCode: number) => {
  const ctx = await setupTest();

  await createStubImpDocker(ctx.bin, { stdout, stderr: '', exitCode });

  const result = await runProcess(['bash', '-s', '--', ctx.secrets, ...buildHostImpArgv([])], {
    stdin: ctx.script,
    env: ctx.env,
  });

  expect(result.exitCode).toBe(1);

  const files = await readdir(ctx.secrets);

  expect(files).toStrictEqual([]);
});

test('it stops with a usage error and saves no token when no CLI argv follows the directory', async () => {
  const ctx = await setupTest();

  const result = await runProcess(['bash', '-s', '--', ctx.secrets], {
    stdin: ctx.script,
    env: ctx.env,
  });

  const files = await readdir(ctx.secrets);

  expect({ exitCode: result.exitCode, stderr: result.stderr.toString() }).toStrictEqual({
    exitCode: 2,
    stderr: 'usage: mint-atc-imp-token.sh <dir> <imp CLI argv>...\n',
  });

  expect(files).toStrictEqual([]);
});

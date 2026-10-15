import { expect, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, readFile, readdir, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runProcess } from '../run-process.ts';
import { createStubImpDocker } from '../test-utils/create-stub-imp-docker.ts';

// The script runs as the host gets it, with real bash reading it on stdin; docker is a stand-in
// first on PATH
async function setupTest() {
  const dir = await mkdtemp(join(tmpdir(), 'mint-atc-imp-token-'));

  onTestFinished(() => rm(dir, { recursive: true, force: true }));

  const bin = join(dir, 'bin');
  const secrets = join(dir, 'secrets');

  await mkdir(bin);
  await mkdir(secrets);

  const script = await readFile(new URL('mint-atc-imp-token.sh', import.meta.url));

  const env = { PATH: `${bin}:${process.env['PATH'] ?? '/usr/bin:/bin'}`, HOME: dir };

  return { bin, secrets, script, env };
}

test('it mints atc-cloud straight into a root-only imp-token in one rename', async () => {
  const ctx = await setupTest();

  await createStubImpDocker(ctx.bin, {
    stdout: 'imp_fixture_minted_token\n',
    stderr: 'impz: token atc-cloud made; impd shows its secret only this once\n',
    exitCode: 0,
  });

  const result = await runProcess(['bash', '-s', '--', ctx.secrets], {
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

  const result = await runProcess(['bash', '-s', '--', ctx.secrets], {
    stdin: ctx.script,
    env: ctx.env,
  });

  const calls = await readFile(join(ctx.bin, 'docker-calls'), 'utf8');

  expect(result.stdout.toString()).toBe('');

  expect(result.stderr.toString()).toBe(
    'impz: token atc-cloud made; impd shows its secret only this once\n',
  );

  expect(calls).toBe(
    '["docker","exec","imp-host","impz","token","new","atc-cloud","--scope","manage","--imps","harness-*","--grantable","glm"]\n',
  );
});

test.each([
  ['the mint prints more than one line', 'imp_fixture_minted_token\nsecond line\n', 0],
  ['impz token new fails', '', 1],
])('it saves no token when %s', async (_label: string, stdout: string, exitCode: number) => {
  const ctx = await setupTest();

  await createStubImpDocker(ctx.bin, { stdout, stderr: '', exitCode });

  const result = await runProcess(['bash', '-s', '--', ctx.secrets], {
    stdin: ctx.script,
    env: ctx.env,
  });

  expect(result.exitCode).toBe(1);

  const files = await readdir(ctx.secrets);

  expect(files).toStrictEqual([]);
});

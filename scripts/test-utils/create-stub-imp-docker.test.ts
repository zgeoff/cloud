import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runProcess } from '../run-process.ts';
import { createStubImpDocker } from './create-stub-imp-docker.ts';

async function setupTest() {
  const dir = await mkdtemp(join(tmpdir(), 'create-stub-imp-docker-'));

  onTestFinished(() => rm(dir, { recursive: true, force: true }));

  return { dir };
}

test('it answers the atc-cloud mint as the scenario says, and logs the call', async () => {
  const ctx = await setupTest();

  const docker = await createStubImpDocker(ctx.dir, {
    stdout: 'imp_fixture_minted_token\n',
    stderr: 'imp: token atc-cloud made; impd shows its secret only this once\n',
    exitCode: 0,
  });

  const result = await runProcess([
    docker,
    'exec',
    'imp-host',
    'imp',
    'token',
    'new',
    'atc-cloud',
    '--scope',
    'manage',
    '--imps',
    'harness-*',
    '--grantable',
    'glm',
  ]);

  expect(result).toStrictEqual({
    exitCode: 0,
    stdout: Buffer.from('imp_fixture_minted_token\n'),
    stderr: Buffer.from('imp: token atc-cloud made; impd shows its secret only this once\n'),
    timedOut: false,
  });

  const calls = await readFile(join(ctx.dir, 'docker-calls'), 'utf8');

  expect(calls).toBe(
    '["docker","exec","imp-host","imp","token","new","atc-cloud","--scope","manage","--imps","harness-*","--grantable","glm"]\n',
  );
});

test('it ends any other call with exit 97', async () => {
  const ctx = await setupTest();
  const docker = await createStubImpDocker(ctx.dir, { stdout: '', stderr: '', exitCode: 0 });
  const result = await runProcess([docker, 'exec', 'imp-host', 'imp', 'token', 'rm', 'atc-cloud']);

  expect(result.exitCode).toBe(97);
  expect(result.stderr.toString()).toBe('unexpected: exec imp-host imp token rm atc-cloud\n');
});

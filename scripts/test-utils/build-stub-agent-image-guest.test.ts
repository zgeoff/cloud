import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildStubAgentImageGuest } from './build-stub-agent-image-guest.ts';
import { buildStubRunner } from './build-stub-runner.ts';

async function setupTest() {
  const dir = await mkdtemp(join(tmpdir(), 'build-stub-agent-image-guest-'));

  onTestFinished(() => rm(dir, { recursive: true, force: true }));

  return { dir };
}

test('it lists the mounted check directory and answers the docker run with the guest result', async () => {
  const ctx = await setupTest();

  const guest = buildStubAgentImageGuest({ guest: { exitCode: 1, stdout: 'FAIL  bun\n' } });
  const stub = buildStubRunner(guest.handler);

  await writeFile(join(ctx.dir, 'gitleaks'), '');
  await writeFile(join(ctx.dir, 'gitleaks.toml'), '');

  const mount = `${ctx.dir}:/run/agent-image-check:ro`;

  const result = await stub.run(['docker', 'run', '--rm', '-i', '-v', mount, 'img', 'bash', '-s']);

  expect(result).toStrictEqual({
    exitCode: 1,
    stdout: Buffer.from('FAIL  bun\n'),
    stderr: Buffer.from(''),
    timedOut: false,
  });

  expect(guest.seen).toStrictEqual([['gitleaks', 'gitleaks.toml']]);
});

test('it lists the directory an imp copy sends, and answers the copy and the exec', async () => {
  const ctx = await setupTest();

  const guest = buildStubAgentImageGuest({ guest: { stdout: '== 0 failed\n' } });
  const stub = buildStubRunner(guest.handler);

  await writeFile(join(ctx.dir, 'gitleaks'), '');

  const copy = await stub.run(['imp', 'cp', ctx.dir, 'agent:/run/agent-image-check']);
  const exec = await stub.run(['imp', 'exec', 'agent', '--', 'bash', '-s']);

  expect(copy.exitCode).toBe(0);
  expect(exec.stdout.toString()).toBe('== 0 failed\n');
  expect(guest.seen).toStrictEqual([['gitleaks']]);
});

test('it answers the imp copy with the scenario’s copy failure', async () => {
  const ctx = await setupTest();

  const guest = buildStubAgentImageGuest({ guest: {}, copy: { exitCode: 3, stderr: 'no imp\n' } });
  const stub = buildStubRunner(guest.handler);

  const result = await stub.run(['imp', 'cp', ctx.dir, 'gone:/run/agent-image-check']);

  expect(result).toStrictEqual({
    exitCode: 3,
    stdout: Buffer.from(''),
    stderr: Buffer.from('no imp\n'),
    timedOut: false,
  });
});

test('it leaves any other call to the next handler', async () => {
  const guest = buildStubAgentImageGuest({ guest: {} });
  const stub = buildStubRunner(guest.handler);

  const result = await stub.run(['docker', 'build', '.']);

  expect(result.exitCode).toBe(97);
  expect(guest.seen).toStrictEqual([]);
});

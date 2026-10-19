import { expect, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildStubCheckAgentImage } from './build-stub-check-agent-image.ts';
import { buildStubRunner } from './build-stub-runner.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'build-stub-check-agent-image-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  await mkdir(join(directory, 'scripts'));

  return { directory };
}

test('it passes the bun check of an archive that holds it', async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner(buildStubCheckAgentImage(0));

  await writeFile(join(ctx.directory, 'scripts/check-agent-image.ts'), '');

  const result = await stub.run([
    'bun',
    join(ctx.directory, 'scripts/check-agent-image.ts'),
    '--imp',
    'agent-check-abc1234',
  ]);

  expect(result).toStrictEqual({
    exitCode: 0,
    stdout: Buffer.from('== 0 failed\n'),
    stderr: Buffer.from(''),
    timedOut: false,
  });
});

test('it fails the bash check of an older archive with the failure count', async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner(buildStubCheckAgentImage(2));

  await writeFile(join(ctx.directory, 'scripts/check-agent-image.sh'), '');

  const result = await stub.run([
    'bash',
    join(ctx.directory, 'scripts/check-agent-image.sh'),
    '--imp',
    'agent-check-abc1234',
  ]);

  expect(result.exitCode).toBe(1);
  expect(result.stdout.toString()).toBe('== 2 failed\n');
});

test('it leaves a check whose script the archive lacks to the next handler', async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner(buildStubCheckAgentImage(0));

  const result = await stub.run([
    'bun',
    join(ctx.directory, 'scripts/check-agent-image.ts'),
    '--imp',
    'agent-check-abc1234',
  ]);

  expect(result.exitCode).toBe(97);
});

import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildStubRunner } from './build-stub-runner.ts';
import { buildStubWriteRestoreJobs } from './build-stub-write-restore-jobs.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'build-stub-write-restore-jobs-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  return { directory };
}

test('it writes each scenario job under the working directory and names it on stdout', async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner(
    buildStubWriteRestoreJobs({ jobs: { 'deploy/nixie/restore-job.yaml': 'kind: Job\n' } }),
  );

  const result = await stub.run(['bun', 'infra/cluster/write-restore-jobs.ts'], {
    cwd: ctx.directory,
  });

  const job = await readFile(join(ctx.directory, 'deploy/nixie/restore-job.yaml'), 'utf8');

  expect({ exitCode: result.exitCode, stdout: result.stdout.toString(), job }).toStrictEqual({
    exitCode: 0,
    stdout: 'write-restore-jobs: wrote deploy/nixie/restore-job.yaml\n',
    job: 'kind: Job\n',
  });
});

test('it fails with the scenario error as the script does for a stack config it cannot read', async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner(
    buildStubWriteRestoreJobs({ error: 'cannot read infra/Pulumi.prod.yaml' }),
  );

  const result = await stub.run(['bun', 'infra/cluster/write-restore-jobs.ts'], {
    cwd: ctx.directory,
  });

  expect({ exitCode: result.exitCode, stderr: result.stderr.toString() }).toStrictEqual({
    exitCode: 1,
    stderr: 'write-restore-jobs: cannot read infra/Pulumi.prod.yaml\n',
  });
});

test('it leaves a run of another script to the other handlers', async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner(buildStubWriteRestoreJobs({}));

  const result = await stub.run(['bun', 'infra/cluster/write-restore-jobs.ts', '--check'], {
    cwd: ctx.directory,
  });

  expect(result.exitCode).toBe(97);
});

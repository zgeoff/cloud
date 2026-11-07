import { expect, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { runProcess } from '../run-process.ts';
import { createRestoreJobFiles } from './create-restore-job-files.ts';

async function setupTest() {
  const root = await mkdtemp(join(tmpdir(), 'create-restore-job-files-'));

  onTestFinished(() => rm(root, { recursive: true, force: true }));

  return {
    root,
    writer: join(import.meta.dir, '../../infra/cluster/write-restore-jobs.ts'),
  };
}

test("it returns the three restore Jobs that the writer's check accepts beside the stack config", async () => {
  const ctx = await setupTest();

  const stack = `config:
  geoff-cloud:atcGateway:
    image: ghcr.io/zgeoff/atc-gateway:5.0.0@sha256:${'1'.repeat(64)}
    backupImage: ghcr.io/zgeoff/atc-gateway-backup:5.0.0-r1@sha256:${'2'.repeat(64)}
    publicURL: https://gateway.example.org
    daemons:
      harbour:
        address: 100.64.0.9:8415
        daemonID: 7a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d
    defaultDaemon: harbour
  geoff-cloud:nixie:
    backupImage: ghcr.io/zgeoff/nixie-backup:2.3.0@sha256:${'3'.repeat(64)}
`;

  const jobs = await createRestoreJobFiles(stack);

  await Promise.all(
    Object.entries({ 'infra/Pulumi.prod.yaml': stack, ...jobs }).map(
      async (entry: readonly [string, string]) => {
        await mkdir(dirname(join(ctx.root, entry[0])), { recursive: true });
        await writeFile(join(ctx.root, entry[0]), entry[1]);
      },
    ),
  );

  const check = await runProcess(['bun', ctx.writer, '--check', ctx.root], {});

  expect({ paths: Object.keys(jobs).toSorted(), exitCode: check.exitCode }).toStrictEqual({
    paths: [
      'deploy/files/restore-job.yaml',
      'deploy/nixie/restore-job.yaml',
      'images/atc-gateway/restore-job.yaml',
    ],
    exitCode: 0,
  });
});

test('it throws with the writer error for a stack config the writer refuses', () => {
  expect(createRestoreJobFiles('config: {}\n')).rejects.toThrowWithMessage(
    Error,
    /write-restore-jobs exited 1: write-restore-jobs: infra\/Pulumi.prod.yaml sets no geoff-cloud:atcGateway or no geoff-cloud:nixie/u,
  );
});

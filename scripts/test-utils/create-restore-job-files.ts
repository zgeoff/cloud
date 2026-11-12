import { onTestFinished } from 'bun:test';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { runProcess } from '../run-process.ts';

const writer = join(import.meta.dir, '../../infra/cluster/write-restore-jobs.ts');

// the restore Jobs the writer writes for the stack config, by path from a checkout's root, for a
// test checkout to commit beside that config
interface RestoreJobFiles {
  readonly 'images/atc-gateway/restore-job.yaml': string;
  readonly 'deploy/nixie/restore-job.yaml': string;
  readonly 'deploy/files/restore-job.yaml': string;
  readonly 'deploy/boxxy/restore-job.yaml': string;
}

const restoreJobPaths = [
  'images/atc-gateway/restore-job.yaml',
  'deploy/nixie/restore-job.yaml',
  'deploy/files/restore-job.yaml',
  'deploy/boxxy/restore-job.yaml',
] as const;

export async function createRestoreJobFiles(stack: string): Promise<RestoreJobFiles> {
  const root = await mkdtemp(join(tmpdir(), 'restore-job-files-'));

  // the folder goes when the test finishes, so this must run inside a test
  onTestFinished(() => rm(root, { recursive: true, force: true }));

  await mkdir(join(root, 'infra'));

  await Promise.all(
    restoreJobPaths.map((path) => mkdir(dirname(join(root, path)), { recursive: true })),
  );

  await writeFile(join(root, 'infra', 'Pulumi.prod.yaml'), stack);

  const result = await runProcess(['bun', writer, root], {});

  if (result.exitCode !== 0) {
    throw new Error(`write-restore-jobs exited ${result.exitCode}: ${result.stderr.toString()}`);
  }

  const [gateway, nixie, files, boxxy] = await Promise.all([
    readFile(join(root, restoreJobPaths[0]), 'utf8'),
    readFile(join(root, restoreJobPaths[1]), 'utf8'),
    readFile(join(root, restoreJobPaths[2]), 'utf8'),
    readFile(join(root, restoreJobPaths[3]), 'utf8'),
  ]);

  return {
    'images/atc-gateway/restore-job.yaml': gateway,
    'deploy/nixie/restore-job.yaml': nixie,
    'deploy/files/restore-job.yaml': files,
    'deploy/boxxy/restore-job.yaml': boxxy,
  };
}

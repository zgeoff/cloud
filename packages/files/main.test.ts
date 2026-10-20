import { expect, onTestFinished, test } from 'bun:test';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createUploadStore } from './create-upload-store.ts';
import { buildMockUpload } from './test-utils/build-mock-upload.ts';

async function setupTest() {
  const dataDir = await mkdtemp(join(tmpdir(), 'files-main-'));

  onTestFinished(() => rm(dataDir, { recursive: true, force: true }));

  // a port the kernel just handed out and nothing holds now
  const probe = Bun.serve({ port: 0, hostname: '127.0.0.1', routes: { '/': new Response() } });
  const port = probe.port;

  await probe.stop(true);

  return { dataDir, port };
}

test('it sweeps an upload that expired while the service was down when it starts, then stops on SIGTERM', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.dataDir, 'files'));

  const store = createUploadStore(join(ctx.dataDir, 'files.db'));

  store.writeUpload(
    buildMockUpload({ id: 'Gone0Gone0Gone0Gone0Go', expiresAt: new Date('2020-01-01T00:00:00Z') }),
  );

  store.close();

  await writeFile(join(ctx.dataDir, 'files', 'Gone0Gone0Gone0Gone0Go'), 'old');

  const child = Bun.spawn([process.execPath, join(import.meta.dir, 'main.ts')], {
    env: {
      PATH: process.env['PATH'] ?? '',
      FILES_PORT: String(ctx.port),
      FILES_DATA_DIR: ctx.dataDir,
      FILES_PUBLIC_URL: 'https://files.example.com',
      FILES_AGENT_TOKEN_SHA256: createHash('sha256').update('agent-token-5d2b').digest('hex'),
      FILES_OWNER_TOKEN_SHA256: createHash('sha256').update('owner-token-c81f').digest('hex'),
    },
    stdout: 'pipe',
    stderr: 'pipe',
  });

  onTestFinished(() => {
    child.kill('SIGKILL');
  });

  const lines: string[] = [];

  // the listening line comes after the sweep at start, so reading up to it waits for the sweep
  for await (const line of child.stdout.pipeThrough(new TextDecoderStream()).values()) {
    lines.push(line);

    if (line.includes('files listening')) {
      break;
    }
  }

  child.kill('SIGTERM');

  const exitCode = await child.exited;
  const files = await readdir(join(ctx.dataDir, 'files'));

  const reopened = createUploadStore(join(ctx.dataDir, 'files.db'));

  onTestFinished(() => {
    reopened.close();
  });

  expect(lines.join('')).toBe(
    `expiry sweep: removed 1 uploads\nfiles listening on port ${ctx.port}\n`,
  );

  expect(exitCode).toBe(0);
  expect(files).toBeEmpty();
  expect(reopened.findUpload('Gone0Gone0Gone0Gone0Go')).toBeNull();
});

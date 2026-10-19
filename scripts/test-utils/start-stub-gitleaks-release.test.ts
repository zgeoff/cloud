import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runProcess } from '../run-process.ts';
import { startStubGitleaksRelease } from './start-stub-gitleaks-release.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'start-stub-gitleaks-release-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  return { directory };
}

test('it serves a tarball at the release URL that holds gitleaks and matches the sum it returns', async () => {
  const ctx = await setupTest();
  const sum = await startStubGitleaksRelease('8.30.1', 'fake gitleaks\n');

  const response = await fetch(
    'https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz',
  );

  const buffer = await response.arrayBuffer();

  const tarball = new Uint8Array(buffer);

  await writeFile(join(ctx.directory, 'release.tar.gz'), tarball);

  await runProcess([
    'tar',
    '-xzf',
    join(ctx.directory, 'release.tar.gz'),
    '-C',
    ctx.directory,
    'gitleaks',
  ]);

  const extracted = await readFile(join(ctx.directory, 'gitleaks'), 'utf8');

  expect(new Bun.CryptoHasher('sha256').update(tarball).digest('hex')).toBe(sum);
  expect(extracted).toBe('fake gitleaks\n');
});

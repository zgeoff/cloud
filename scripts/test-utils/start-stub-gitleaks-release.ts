import { onTestFinished } from 'bun:test';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { HttpResponse, http } from 'msw';
import { server } from '../mocks/node.ts';
import { runProcess } from '../run-process.ts';

// Stands in for a gitleaks release on GitHub, for the current test: its linux_x64 tarball, a real
// tar.gz that holds a `gitleaks` file with the given content, at the release's download URL.
// Returns the tarball's sha256, as the release's checksums file lists it.
export async function startStubGitleaksRelease(version: string, content: string): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), 'stub-gitleaks-release-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  await writeFile(join(directory, 'gitleaks'), content, { mode: 0o755 });
  await runProcess(['tar', '-czf', join(directory, 'release.tar.gz'), '-C', directory, 'gitleaks']);

  const tarball = await readFile(join(directory, 'release.tar.gz'));

  const url = `https://github.com/gitleaks/gitleaks/releases/download/v${version}/gitleaks_${version}_linux_x64.tar.gz`;

  server.use(http.get(url, () => HttpResponse.arrayBuffer(new Uint8Array(tarball).buffer)));

  return new Bun.CryptoHasher('sha256').update(tarball).digest('hex');
}

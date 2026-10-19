import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runProcess } from '../run-process.ts';

// Creates a real npm package tarball with real tar: package/package.json holding the manifest, as
// `npm pack` lays it out. It works in a temp directory it removes, and gives the tarball's bytes.
export async function createNPMTarball(
  manifest: Readonly<Record<string, string>>,
): Promise<Uint8Array> {
  const directory = await mkdtemp(join(tmpdir(), 'npm-tarball-'));

  await mkdir(join(directory, 'package'));
  await writeFile(join(directory, 'package/package.json'), `${JSON.stringify(manifest)}\n`);

  const packed = await runProcess([
    'tar',
    '-czf',
    join(directory, 'package.tgz'),
    '-C',
    directory,
    'package',
  ]);

  const bytes = packed.exitCode === 0 ? await readFile(join(directory, 'package.tgz')) : null;

  await rm(directory, { recursive: true, force: true });

  if (bytes === null) {
    throw new Error(`tar exited ${packed.exitCode}: ${packed.stderr.toString()}`);
  }

  return new Uint8Array(bytes);
}

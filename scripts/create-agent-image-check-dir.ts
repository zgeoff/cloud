import { copyFile, mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { ExitError } from './exit-error.ts';
import type { ScriptIO } from './run-or-exit.ts';
import { runOrExit } from './run-or-exit.ts';

export interface AgentImageCheckDirInput {
  // a directory the caller owns and removes
  readonly work: string;
  readonly repo: string;
  readonly pins: ReadonlyMap<string, string>;
}

// Creates <work>/agent-image-check, which the check mounts or copies to /run/agent-image-check in
// the image: the gitleaks binary the Dockerfile pins, checked against the Dockerfile's sum, and
// the gitleaks config. Returns its path.
export async function createAgentImageCheckDir(
  io: Readonly<ScriptIO>,
  input: Readonly<AgentImageCheckDirInput>,
): Promise<string> {
  const tarball = join(input.work, 'gitleaks.tar.gz');
  const dir = join(input.work, 'agent-image-check');

  const bytes = await readGitleaks(input.pins);

  await writeFile(tarball, bytes);
  await mkdir(dir);
  await runOrExit(io, ['tar', '-xzf', tarball, '-C', dir, 'gitleaks']);
  await copyFile(join(input.repo, 'scripts/agent-image-gitleaks.toml'), join(dir, 'gitleaks.toml'));

  return dir;
}

// the linux_x64 tarball of the gitleaks release, whose line in the release's checksums file the
// Dockerfile pins as GITLEAKS_SHA256
async function readGitleaks(pins: ReadonlyMap<string, string>) {
  const version = pins.get('GITLEAKS_VERSION');
  const sum = pins.get('GITLEAKS_SHA256');

  if (version === undefined || sum === undefined) {
    throw new ExitError(1, 'images/agent/Dockerfile pins no GITLEAKS_VERSION and GITLEAKS_SHA256');
  }

  const name = `gitleaks_${version}_linux_x64.tar.gz`;

  const bytes = await readRelease(version, name);

  const actual = new Bun.CryptoHasher('sha256').update(bytes).digest('hex');

  if (actual !== sum) {
    throw new ExitError(1, `${name} has sha256 ${actual}, but images/agent/Dockerfile pins ${sum}`);
  }

  return bytes;
}

async function readRelease(version: string, name: string) {
  const url = `https://github.com/gitleaks/gitleaks/releases/download/v${version}/${name}`;

  const response = await fetch(url, { signal: AbortSignal.timeout(120_000) });

  if (!response.ok) {
    throw new ExitError(1, `cannot download ${name}: HTTP ${response.status}`);
  }

  const buffer = await response.arrayBuffer();

  return new Uint8Array(buffer);
}

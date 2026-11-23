import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { findJSONField } from './find-json-field.ts';
import type { ScriptIO } from './run-or-exit.ts';

export interface TargetImageFiles {
  // an atc config file: JSON with targets.<name>.image
  readonly atcConfigs: readonly string[];

  // a NixOS file that sets `image = "agent-..."` for the atc daemon's targets, and the clone that
  // holds it
  readonly nix: { readonly clone: string; readonly file: string };
}

// the commits of the NixOS file whose changes count: a change merged before the host switched
// leaves the running target's image on a removed line
const nixHistoryCommits = '3';

// Reads the agent images that atc targets boot. A config file that does not exist names none. A
// file that cannot be read, a config that is not JSON, or a git log that fails throws, so the
// caller keeps every image rather than guess.
export async function loadTargetAgentImages(
  io: Readonly<Pick<ScriptIO, 'run'>>,
  files: Readonly<TargetImageFiles>,
): Promise<string[]> {
  const configs = await Promise.all(files.atcConfigs.map((file) => readText(file)));
  const nixFile = await readText(join(files.nix.clone, files.nix.file));

  const history = await io.run([
    'git',
    '-C',
    files.nix.clone,
    'log',
    '-n',
    nixHistoryCommits,
    '-p',
    '-U0',
    '--format=',
    '--',
    files.nix.file,
  ]);

  if (history.exitCode !== 0) {
    throw new Error(`git log of ${files.nix.file} failed: ${history.stderr.toString().trim()}`);
  }

  return [
    ...configs.flatMap((text) => getConfigImages(text)),
    ...getNixImages(nixFile),
    ...getNixImages(history.stdout.toString()),
  ];
}

async function readText(file: string): Promise<string> {
  try {
    return await readFile(file, 'utf8');
  } catch (error) {
    if (error instanceof Error && 'code' in error && error.code === 'ENOENT') {
      return '';
    }

    throw error;
  }
}

function getConfigImages(text: string): string[] {
  if (text === '') {
    return [];
  }

  const parsed: unknown = JSON.parse(text);
  const targets = findJSONField(parsed, 'targets');

  if (typeof targets !== 'object' || targets === null) {
    return [];
  }

  return Object.values(targets).flatMap((target) => {
    const image = findJSONField(target, 'image');

    return typeof image === 'string' ? [image] : [];
  });
}

// a changed line of the file's history starts with + or -
const nixImagePattern = /^[-+ ]?\s*image\s*=\s*"(?<image>agent-[^"]+)"\s*;/gmu;

function getNixImages(text: string): string[] {
  return [...text.matchAll(nixImagePattern)].map((match) => match.groups?.['image'] ?? '');
}

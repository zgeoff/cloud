import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { deployedHostTag } from './constants.ts';
import { findJSONField } from './find-json-field.ts';
import type { ScriptIO } from './run-or-exit.ts';
import type { TargetImageFiles } from './types.ts';

// Reads the agent images, or the `agent` alias, that atc targets boot: the config files, and the NixOS file in the clone
// and at the commit the host runs. A config file that does not exist names none. Anything else that
// cannot be read throws, so the caller keeps every image rather than guess.
export async function readTargetAgentImages(
  io: Readonly<Pick<ScriptIO, 'run'>>,
  files: Readonly<TargetImageFiles>,
): Promise<string[]> {
  const configs = await Promise.all(files.atcConfigs.map((file) => readText(file)));
  const nixFile = await readText(join(files.nix.clone, files.nix.file));

  const deployed = await io.run([
    'git',
    '-C',
    files.nix.clone,
    'show',
    `${deployedHostTag}:${files.nix.file}`,
  ]);

  if (deployed.exitCode !== 0) {
    throw new Error(
      `git show of ${files.nix.file} at deployed/host failed: ${deployed.stderr.toString().trim()}`,
    );
  }

  return [
    ...configs.flatMap((text) => getConfigImages(text)),
    ...getNixImages(nixFile),
    ...getNixImages(deployed.stdout.toString()),
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

const nixImagePattern = /^\s*image\s*=\s*"(?<image>agent(?:-[^"]+)?)"\s*;/gmu;

function getNixImages(text: string): string[] {
  return [...text.matchAll(nixImagePattern)].map((match) => match.groups?.['image'] ?? '');
}

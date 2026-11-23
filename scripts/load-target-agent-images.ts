import { readFile } from 'node:fs/promises';
import { findJSONField } from './find-json-field.ts';

export interface TargetImageFiles {
  // an atc config file: JSON with targets.<name>.image
  readonly atcConfigs: readonly string[];

  // a NixOS file that sets `image = "agent-..."` for the atc daemon's targets
  readonly nixFiles: readonly string[];
}

// Reads the agent images that atc targets boot. A file that is missing or unreadable names none.
export async function loadTargetAgentImages(files: Readonly<TargetImageFiles>): Promise<string[]> {
  const configs = await Promise.all(files.atcConfigs.map((file) => readText(file)));
  const nixes = await Promise.all(files.nixFiles.map((file) => readText(file)));

  return [
    ...configs.flatMap((text) => getConfigImages(text)),
    ...nixes.flatMap((text) => getNixImages(text)),
  ];
}

async function readText(file: string): Promise<string> {
  try {
    return await readFile(file, 'utf8');
  } catch {
    return '';
  }
}

function getConfigImages(text: string): string[] {
  let parsed: unknown;

  try {
    parsed = JSON.parse(text);
  } catch {
    return [];
  }

  const targets = findJSONField(parsed, 'targets');

  if (typeof targets !== 'object' || targets === null) {
    return [];
  }

  return Object.values(targets).flatMap((target) => {
    const image = findJSONField(target, 'image');

    return typeof image === 'string' ? [image] : [];
  });
}

const nixImagePattern = /^\s*image\s*=\s*"(?<image>agent-[\da-f]{7,40})"\s*;/gmu;

function getNixImages(text: string): string[] {
  return [...text.matchAll(nixImagePattern)].map((match) => match.groups?.['image'] ?? '');
}

import { chmod, copyFile, readFile, rename, stat, writeFile } from 'node:fs/promises';
import { ExitError } from './exit-error.ts';
import { findJSONField } from './find-json-field.ts';

export interface CloudTargetImageChange {
  readonly config: string;
  readonly image: string;
  readonly guestATC: string;

  // milliseconds since the epoch
  readonly now: number;
}

// Copies the atc config to <config>.bak-<UTC stamp>-pre-<image> with its mode, then sets
// targets.cloud.image and targets.cloud.guestATC and changes nothing else. Returns the backup's path.
export async function writeCloudTargetImage(
  change: Readonly<CloudTargetImageChange>,
): Promise<string> {
  const backup = `${change.config}.bak-${formatStamp(change.now)}-pre-${change.image}`;

  const info = await stat(change.config);

  await copyFile(change.config, backup);
  await chmod(backup, info.mode & 0o7777);
  await writeConfig(change);

  return backup;
}

// the stamp `date -u +%Y%m%dT%H%M%SZ` prints
function formatStamp(now: number) {
  return new Date(now)
    .toISOString()
    .replace(/\.\d{3}Z$/u, 'Z')
    .replaceAll(/[-:]/gu, '');
}

// Other sessions can write the same file, so the edit reads it again and replaces it in one
// rename. The file holds the daemon's settings, so it stays readable by its owner only.
async function writeConfig(change: Readonly<CloudTargetImageChange>) {
  const text = await readFile(change.config, 'utf8');

  const parsed: unknown = JSON.parse(text);
  const target = findJSONField(findJSONField(parsed, 'targets'), 'cloud');

  if (typeof target !== 'object' || target === null) {
    throw new ExitError(1, `${change.config} has no targets.cloud object`);
  }

  Reflect.set(target, 'image', change.image);
  Reflect.set(target, 'guestATC', change.guestATC);

  await writeFile(`${change.config}.new`, `${JSON.stringify(parsed, null, 2)}\n`, { mode: 0o600 });
  await chmod(`${change.config}.new`, 0o600);
  await rename(`${change.config}.new`, change.config);
}

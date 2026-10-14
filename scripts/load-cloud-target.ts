import { readFile } from 'node:fs/promises';
import { ExitError } from './exit-error.ts';
import { findJSONField } from './find-json-field.ts';

export interface CloudTarget {
  readonly image?: string;
  readonly guestATC?: string;
}

// Loads the image fields of an atc config's targets.cloud. A config that is missing, is not JSON,
// or holds no targets.cloud object stops the script with one message for all three.
export async function loadCloudTarget(config: string): Promise<CloudTarget> {
  const target = await readCloudTarget(config);

  if (typeof target !== 'object' || target === null || Array.isArray(target)) {
    throw new ExitError(1, `${config} has no targets.cloud object`);
  }

  return {
    image: toOptionalString(target, 'image'),
    guestATC: toOptionalString(target, 'guestATC'),
  };
}

async function readCloudTarget(config: string): Promise<unknown> {
  try {
    const text = await readFile(config, 'utf8');

    const parsed: unknown = JSON.parse(text);

    return findJSONField(findJSONField(parsed, 'targets'), 'cloud');
  } catch {
    return undefined;
  }
}

function toOptionalString(record: object, key: string) {
  const value = findJSONField(record, key);

  return typeof value === 'string' ? value : undefined;
}

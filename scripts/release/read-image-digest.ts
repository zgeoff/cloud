import { findJSONField } from '../find-json-field.ts';
import type { Runner } from '../run-process.ts';
import { runChecked } from './run-checked.ts';

export async function readImageDigest(run: Runner, ref: string): Promise<string | Error> {
  const manifest = await runChecked(run, [
    'docker',
    'buildx',
    'imagetools',
    'inspect',
    ref,
    '--format',
    '{{json .Manifest}}',
  ]);

  if (manifest instanceof Error) {
    return manifest;
  }

  const digest = findJSONField(tryParseJSON(manifest), 'digest');

  return typeof digest === 'string' && /^sha256:[0-9a-f]{64}$/u.test(digest)
    ? digest
    : new Error(`${ref} names no sha256 digest`);
}

function tryParseJSON(text: string): unknown {
  try {
    const value: unknown = JSON.parse(text);

    return value;
  } catch {
    return null;
  }
}

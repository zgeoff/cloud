import { findJSONField } from './find-json-field.ts';
import type { AliasVerdict, ImpAnswer } from './types.ts';

// Reads the answer of `impz info --json`. An impd that does not report the imageAliases feature
// skips the move. Any other answer that is not the feature list fails it.
export function pickAliasVerdictForInfo(info: Readonly<ImpAnswer>): AliasVerdict {
  if (info.timedOut) {
    return { kind: 'fail', reason: 'impz info timed out' };
  }

  if (info.exitCode !== 0) {
    return { kind: 'fail', reason: `impz info exited ${info.exitCode}: ${info.stderr.trim()}` };
  }

  const features = findJSONField(parseJSON(info.stdout), 'features');

  if (typeof features !== 'object' || features === null) {
    return { kind: 'fail', reason: 'impz info printed no feature list' };
  }

  return findJSONField(features, 'imageAliases') === true
    ? { kind: 'ok' }
    : { kind: 'skip', reason: 'impd lacks the imageAliases feature' };
}

function parseJSON(text: string): unknown {
  try {
    const value: unknown = JSON.parse(text);

    return value;
  } catch {
    return undefined;
  }
}

import { findPinMatch } from './find-pin-match.ts';
import type { Pin, ReleaseRecord } from './release-registry.ts';

// each pin's values by pin id, then by named group
export type PinValues = Readonly<Record<string, Readonly<Record<string, string>>>>;

// Collects what each of the record's pin lines holds, from the files' contents. A pin line that is
// missing or doubled, or two lines of one pin that hold different values for one group, give the
// Error.
export function collectPinValues(
  record: ReleaseRecord,
  files: Readonly<Record<string, string>>,
): PinValues | Error {
  const values: Record<string, Readonly<Record<string, string>>> = {};

  for (const pin of record.pins) {
    const held = collectHeldParts(pin, files);

    if (held instanceof Error) {
      return held;
    }

    values[pin.id] = held;
  }

  return values;
}

function collectHeldParts(pin: Pin, files: Readonly<Record<string, string>>) {
  const held: Record<string, string> = {};

  for (const line of pin.lines) {
    const match = findPinMatch(files, line);

    if (match instanceof Error) {
      return match;
    }

    const conflict = findConflict(pin.id, held, match.groups);

    if (conflict !== undefined) {
      return conflict;
    }

    Object.assign(held, match.groups);
  }

  return held;
}

function findConflict(
  id: string,
  held: Readonly<Record<string, string>>,
  groups: Readonly<Record<string, string>>,
) {
  const group = Object.keys(groups).find(
    (name) => held[name] !== undefined && held[name] !== groups[name],
  );

  return group === undefined
    ? undefined
    : new Error(`${id} holds ${held[group] ?? ''} and ${groups[group] ?? ''} for ${group}`);
}

import { findPinMatch } from './find-pin-match.ts';
import type { PinPart, ReleaseRecord } from './release-registry.ts';

// The version that each of the record's pins holds, in the record's order: the version part of
// the pin's first line that has one. A pin line that is missing, or that more than one line
// holds, gives the Error.
export function findPinnedVersions(
  record: ReleaseRecord,
  files: Readonly<Record<string, string>>,
): readonly string[] | Error {
  const versions: string[] = [];

  for (const pin of record.pins) {
    const line = pin.lines.find((each) =>
      Object.values(each.parts).some((part) => part.kind === 'version'),
    );

    const group = Object.entries(line?.parts ?? {}).find(
      (entry: readonly [string, PinPart]) => entry[1].kind === 'version',
    )?.[0];

    const match =
      line === undefined ? new Error(`${pin.id} has no version part`) : findPinMatch(files, line);

    if (match instanceof Error) {
      return match;
    }

    versions.push(match.groups[group ?? ''] ?? '');
  }

  return versions;
}

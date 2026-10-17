import type { PinValues } from './collect-pin-values.ts';
import { findPinMatch } from './find-pin-match.ts';
import { parsePinTable } from './parse-pin-table.ts';
import { pinTableFile } from './pin-table-file.ts';
import { releaseRegistry } from './release-registry.ts';

// Every disagreement between the pin lines in the files and the pin table, one line each: a part
// that a line holds with another value than the table, a pin the table lacks, and an entry the
// registry lacks. An empty list means every pin matches the table.
export function findPinTableMismatches(files: Readonly<Record<string, string>>): readonly string[] {
  const table = loadTable(files[pinTableFile]);

  if (typeof table === 'string') {
    return [table];
  }

  const ids = new Set(releaseRegistry.flatMap((record) => record.pins.map((pin) => pin.id)));

  const extra = Object.keys(table)
    .filter((id) => !ids.has(id))
    .map((id) => `${pinTableFile} holds ${id}, which no registry record pins`);

  return [...collectLineMismatches(files, table), ...extra];
}

function loadTable(text: string | undefined): PinValues | string {
  if (text === undefined) {
    return `${pinTableFile} is missing`;
  }

  const table = parsePinTable(text);

  return table instanceof Error ? table.message : table;
}

function collectLineMismatches(files: Readonly<Record<string, string>>, table: PinValues) {
  return releaseRegistry.flatMap((record) =>
    record.pins.flatMap((pin) => {
      const entry = table[pin.id];

      if (entry === undefined) {
        return [`${pinTableFile} lacks ${pin.id}`];
      }

      return pin.lines.flatMap((line) => {
        const match = findPinMatch(files, line);

        if (match instanceof Error) {
          return [match.message];
        }

        return Object.keys(match.groups)
          .filter((group) => entry[group] !== match.groups[group])
          .map(
            (group) =>
              `${pin.id}: ${line.file}:${match.index + 1} holds ${match.groups[group] ?? 'nothing'} for ${group}, but ${pinTableFile} holds ${entry[group] ?? 'nothing'}`,
          );
      });
    }),
  );
}

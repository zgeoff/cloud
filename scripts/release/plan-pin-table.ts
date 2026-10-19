import { collectPinValues } from './collect-pin-values.ts';
import type { PinValues } from './collect-pin-values.ts';
import { parsePinTable } from './parse-pin-table.ts';
import { pinTableFile } from './pin-table-file.ts';
import type { ReleaseRecord } from './release-registry.ts';
import { releaseRegistry } from './release-registry.ts';

export function planPinTable(
  records: readonly ReleaseRecord[],
  files: Readonly<Record<string, string>>,
): string | Error {
  const text = files[pinTableFile];
  const table = text === undefined ? {} : parsePinTable(text);

  if (table instanceof Error) {
    return table;
  }

  const takenRecords = text === undefined ? releaseRegistry : records;
  const taken = collectTakenValues(takenRecords, files);

  return taken instanceof Error ? taken : renderTable({ ...table, ...taken });
}

function collectTakenValues(
  records: readonly ReleaseRecord[],
  files: Readonly<Record<string, string>>,
): PinValues | Error {
  const entries: Record<string, PinValues[string]> = {};

  for (const record of records) {
    const values = collectPinValues(record, files);

    if (values instanceof Error) {
      return values;
    }

    Object.assign(entries, values);
  }

  return entries;
}

function renderTable(entries: PinValues) {
  const ids = releaseRegistry.flatMap((record) => record.pins.map((pin) => pin.id));
  const others = Object.keys(entries).filter((id) => !ids.includes(id));

  const ordered = [...ids, ...others].flatMap((id) =>
    entries[id] === undefined ? [] : [[id, entries[id]] as const],
  );

  return `${JSON.stringify(Object.fromEntries(ordered), null, 2)}\n`;
}

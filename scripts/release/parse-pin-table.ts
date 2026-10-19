import type { PinValues } from './collect-pin-values.ts';
import { pinTableFile } from './pin-table-file.ts';

export function parsePinTable(text: string): PinValues | Error {
  const table = tryParseJSON(text);

  if (!isObject(table)) {
    return new Error(`${pinTableFile} holds no JSON object`);
  }

  // Object.fromEntries keeps every key as an own field, where an assignment to __proto__ would
  // set the prototype and hide the entry from the check
  const entries: [string, Readonly<Record<string, string>>][] = [];

  for (const id of Object.keys(table)) {
    const entry = collectStringFields(Reflect.get(table, id));

    if (entry === null) {
      return new Error(`${pinTableFile} holds ${id} as no object of strings`);
    }

    entries.push([id, entry]);
  }

  return Object.fromEntries(entries);
}

function tryParseJSON(text: string): unknown {
  try {
    const value: unknown = JSON.parse(text);

    return value;
  } catch {
    return null;
  }
}

function isObject(value: unknown): value is object {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function collectStringFields(value: unknown): Readonly<Record<string, string>> | null {
  if (!isObject(value)) {
    return null;
  }

  const fields: [string, string][] = [];

  for (const key of Object.keys(value)) {
    const field: unknown = Reflect.get(value, key);

    if (typeof field !== 'string') {
      return null;
    }

    fields.push([key, field]);
  }

  return Object.fromEntries(fields);
}

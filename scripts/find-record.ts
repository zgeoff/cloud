import { findJSONField } from './find-json-field.ts';

export function findRecord(list: unknown, key: string, value: string): unknown {
  if (!Array.isArray(list)) {
    return undefined;
  }

  const records: readonly unknown[] = list;

  return records.find((record) => findJSONField(record, key) === value);
}

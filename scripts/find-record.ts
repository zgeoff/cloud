import { findJSONField } from './find-json-field.ts';

// Finds the first record of a parsed JSON list whose field holds the value, as jq's
// `any(.[]; .<key> == $value)` tests for one; undefined when the list is not a list or none does
export function findRecord(list: unknown, key: string, value: string): unknown {
  if (!Array.isArray(list)) {
    return undefined;
  }

  const records: readonly unknown[] = list;

  return records.find((record) => findJSONField(record, key) === value);
}

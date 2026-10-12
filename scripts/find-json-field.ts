// Finds a field of a parsed JSON value, or undefined when the value is not an object or lacks it
export function findJSONField(value: unknown, key: string): unknown {
  if (typeof value !== 'object' || value === null) {
    return undefined;
  }

  const field: unknown = Reflect.get(value, key);

  return field;
}

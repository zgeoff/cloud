export function findJSONField(value: unknown, key: string): unknown {
  if (typeof value !== 'object' || value === null) {
    return undefined;
  }

  const field: unknown = Reflect.get(value, key);

  return field;
}

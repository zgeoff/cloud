// a JSON schema's fields as `path: type` lines, sorted, with `?` on an optional field and `*` for
// a record's keys, so a test can compare a schema's shape with a pinned list
export function collectSchemaFields(schema: unknown, path = ''): readonly string[] {
  if (!isObject(schema)) {
    return [];
  }

  const properties = schema['properties'];

  if (isObject(properties)) {
    const required = Array.isArray(schema['required']) ? schema['required'] : [];

    return Object.entries(properties)
      .flatMap(([key, child]) => {
        const name = required.includes(key) ? key : `${key}?`;
        const childPath = path === '' ? name : `${path}.${name}`;

        return collectSchemaFields(child, childPath);
      })
      .toSorted();
  }

  const additional = schema['additionalProperties'];

  if (isObject(additional)) {
    return collectSchemaFields(additional, `${path}.*`);
  }

  return [`${path}: ${String(schema['type'])}`];
}

function isObject(value: unknown): value is Readonly<Record<string, unknown>> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

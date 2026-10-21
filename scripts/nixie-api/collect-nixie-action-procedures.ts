import { findJSONField } from '../find-json-field.ts';

export function collectNixieActionProcedures(document: unknown): string[] {
  const paths = findJSONField(document, 'paths');

  if (typeof paths !== 'object' || paths === null) {
    return [];
  }

  return Object.entries(paths)
    .filter(([, operation]) => hasActionID(operation))
    .map(([path]) => path.replace(/^\//u, ''));
}

// nixie names a message's client action ID clientMessageId, the name its client design gives it
const actionIDFields = ['clientActionID', 'clientMessageId'];

function hasActionID(operation: unknown): boolean {
  const properties = [
    'post',
    'requestBody',
    'content',
    'application/json',
    'schema',
    'properties',
  ].reduce<unknown>((value, key) => findJSONField(value, key), operation);

  return actionIDFields.some((field) => findJSONField(properties, field) !== undefined);
}

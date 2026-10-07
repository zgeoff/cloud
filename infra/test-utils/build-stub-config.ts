import type { Config } from '@pulumi/pulumi';

// A stand-in for Pulumi's Config, over the stack config's raw values by bare key, as
// `pulumi config set` stores them: strings, with an object as its JSON text. get returns
// the raw string and getObject JSON-parses it without checking its shape, as Config does;
// a key the stack does not set reads as undefined from both.
export function buildStubConfig(
  values: Readonly<Record<string, string>>,
): Pick<Config, 'get' | 'getObject'> {
  return {
    get: (key) => findValue(values, key),
    getObject: (key) => {
      const raw = values[key];

      return raw === undefined ? undefined : parseJSON(raw);
    },
  };
}

// Config's own get types its value as the caller's K unchecked, and getObject its parsed
// value as the caller's T, so the stand-in does the same
/* oxlint-disable typescript/no-unsafe-type-assertion, typescript/no-unnecessary-type-parameters */
function findValue<K extends string>(
  values: Readonly<Record<string, string>>,
  key: string,
): K | undefined {
  return values[key] as K | undefined;
}

function parseJSON<T>(raw: string): T {
  return JSON.parse(raw) as T;
}

import { RunError } from '@pulumi/pulumi';
import type { Config } from '@pulumi/pulumi';

// Stand-in for Pulumi's Config over raw stack values: get returns the string, getObject
// JSON-parses it unchecked, and a missing key reads undefined. Non-JSON throws Config's
// RunError naming project, key, and value (ConfigTypeError itself is unexported).
export function buildStubConfig(
  values: Readonly<Record<string, string>>,
): Pick<Config, 'get' | 'getObject'> {
  return {
    get: (key) => findValue(values, key),
    getObject: (key) => {
      const raw = values[key];

      return raw === undefined ? undefined : parseJSON(key, raw);
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

// Pulumi.yaml's name, which a bare `new Config()` takes as its namespace
const projectName = 'geoff-cloud';

function parseJSON<T>(key: string, raw: string): T {
  try {
    return JSON.parse(raw) as T;
  } catch {
    throw new RunError(
      `Configuration '${projectName}:${key}' value '${raw}' is not a valid JSON object`,
    );
  }
}

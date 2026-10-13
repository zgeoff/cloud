import { RunError } from '@pulumi/pulumi';
import type { Config } from '@pulumi/pulumi';

// Stand-in for Pulumi's Config over raw stack values: get returns the string, getBoolean reads
// "true" and "false", getObject JSON-parses unchecked, a missing key reads undefined. Any other
// value throws Config's RunError naming project, key and value (ConfigTypeError is unexported).
export function buildStubConfig(
  values: Readonly<Record<string, string>>,
): Pick<Config, 'get' | 'getBoolean' | 'getObject'> {
  return {
    get: (key) => findValue(values, key),
    getBoolean: (key) => {
      const raw = values[key];

      return raw === undefined ? undefined : parseBoolean(key, raw);
    },
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

function parseBoolean(key: string, raw: string): boolean {
  if (raw === 'true' || raw === 'false') {
    return raw === 'true';
  }

  throw new RunError(`Configuration '${projectName}:${key}' value '${raw}' is not a valid boolean`);
}

function parseJSON<T>(key: string, raw: string): T {
  try {
    return JSON.parse(raw) as T;
  } catch {
    throw new RunError(
      `Configuration '${projectName}:${key}' value '${raw}' is not a valid JSON object`,
    );
  }
}

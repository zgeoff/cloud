import { RunError, secret } from '@pulumi/pulumi';
import type { StackConfig } from '../inputs/types.ts';

export function buildStubConfig(values: Readonly<Record<string, string>>): StackConfig {
  return {
    get: (key) => values[key],
    getBoolean: (key) => {
      const raw = values[key];

      return raw === undefined ? undefined : isConfigTrue(key, raw);
    },
    getObject: (key) => {
      const raw = values[key];

      return raw === undefined ? undefined : parseJSON(key, raw);
    },
    getSecret: (key) => {
      const raw = values[key];

      return raw === undefined ? undefined : secret(raw);
    },
  };
}

// Pulumi.yaml's name, which a bare `new Config()` takes as its namespace
const projectName = 'geoff-cloud';

function isConfigTrue(key: string, raw: string): boolean {
  if (raw === 'true' || raw === 'false') {
    return raw === 'true';
  }

  // Config's own ConfigTypeError is unexported, so the stand-in throws RunError
  throw new RunError(`Configuration '${projectName}:${key}' value '${raw}' is not a valid boolean`);
}

function parseJSON(key: string, raw: string): unknown {
  try {
    const parsed: unknown = JSON.parse(raw);

    return parsed;
  } catch {
    throw new RunError(
      `Configuration '${projectName}:${key}' value '${raw}' is not a valid JSON object`,
    );
  }
}

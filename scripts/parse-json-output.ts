import { ExitError } from './exit-error.ts';

export function parseJSONOutput(text: string, source: string): unknown {
  try {
    const value: unknown = JSON.parse(text);

    return value;
  } catch {
    throw new ExitError(1, `no JSON from ${source}`);
  }
}

import { ExitError } from './exit-error.ts';

// Parses a tool's JSON answer or a JSON file; anything else stops the script, as a failed jq would
export function parseJSONOutput(text: string, source: string): unknown {
  try {
    const value: unknown = JSON.parse(text);

    return value;
  } catch {
    throw new ExitError(1, `no JSON from ${source}`);
  }
}

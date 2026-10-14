import { parseJSONOutput } from './parse-json-output.ts';
import type { ScriptIO } from './run-or-exit.ts';
import { runOrExit } from './run-or-exit.ts';

// Reads one of imp's --json listings through its CLI; a failed call stops the script
export async function readImpJSON(
  io: Readonly<ScriptIO>,
  args: readonly string[],
): Promise<unknown> {
  const result = await runOrExit(io, ['imp', ...args]);

  return parseJSONOutput(result.stdout.toString(), `imp ${args.join(' ')}`);
}

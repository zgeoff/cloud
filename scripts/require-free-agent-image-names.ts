import { ExitError } from './exit-error.ts';
import { findRecord } from './find-record.ts';
import { readImpJSON } from './read-imp-json.ts';
import type { ScriptIO } from './run-or-exit.ts';

export interface AgentImageNames {
  readonly image: string;
  readonly check: string;
}

// Refuses an image or check imp name that the imp host already holds
export async function requireFreeAgentImageNames(
  io: Readonly<ScriptIO>,
  names: AgentImageNames,
): Promise<void> {
  const images = await readImpJSON(io, ['image', 'ls', '--json']);

  if (findRecord(images, 'name', names.image) !== undefined) {
    throw new ExitError(
      1,
      `image ${names.image} already exists: remove it with imp image rm, or build another commit`,
    );
  }

  const imps = await readImpJSON(io, ['ls', '--json']);

  if (findRecord(imps, 'name', names.check) !== undefined) {
    throw new ExitError(1, `imp ${names.check} already exists: remove it with imp rm first`);
  }
}

import { ExitError } from './exit-error.ts';
import { findRecord } from './find-record.ts';
import { formatImpCommand, loadImpJSON } from './imp-cli.ts';
import type { ScriptIO } from './run-or-exit.ts';

export interface AgentImageNames {
  readonly image: string;
  readonly check: string;
}

export async function requireFreeAgentImageNames(
  io: Readonly<ScriptIO>,
  names: AgentImageNames,
): Promise<void> {
  const images = await loadImpJSON(io, ['image', 'ls']);

  if (findRecord(images, 'name', names.image) !== undefined) {
    throw new ExitError(
      1,
      `image ${names.image} already exists: remove it with ${formatImpCommand(['image', 'rm'])}, or build another commit`,
    );
  }

  const imps = await loadImpJSON(io, ['ls']);

  if (findRecord(imps, 'name', names.check) !== undefined) {
    throw new ExitError(
      1,
      `imp ${names.check} already exists: remove it with ${formatImpCommand(['rm'])} first`,
    );
  }
}

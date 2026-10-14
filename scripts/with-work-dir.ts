import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { InterruptibleIO } from './subscribe-to-interrupts.ts';

// Runs body in a fresh directory, <temp dir>/<prefix>XXXXXX, and removes the directory once body
// ends or an interrupt stops the script. The removal waits for mkdtemp, which a signal can land in.
export async function withWorkDir<T>(
  io: Readonly<Pick<InterruptibleIO, 'registerCleanup'>>,
  prefix: string,
  body: (work: string) => Promise<T>,
): Promise<T> {
  const creating = mkdtemp(join(tmpdir(), prefix));

  const removeWork = async () => {
    const created = await creating;

    await rm(created, { recursive: true, force: true });
  };

  const dropCleanup = io.registerCleanup(removeWork);

  try {
    const work = await creating;

    return await body(work);
  } finally {
    await removeWork();

    dropCleanup();
  }
}

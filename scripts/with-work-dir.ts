import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { InterruptibleIO } from './subscribe-to-interrupts.ts';

export async function withWorkDir<T>(
  io: Readonly<Pick<InterruptibleIO, 'registerCleanup'>>,
  prefix: string,
  body: (work: string) => Promise<T>,
): Promise<T> {
  const creating = mkdtemp(join(tmpdir(), prefix));

  const removeWork = async () => {
    // a signal can land while mkdtemp runs, so the removal waits for it
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

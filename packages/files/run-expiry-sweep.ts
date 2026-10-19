import { rmSync } from 'node:fs';
import { join } from 'node:path';
import type { UploadStore } from './create-upload-store.ts';

interface ExpirySweepInputs {
  readonly store: Pick<UploadStore, 'readExpiredIDs' | 'removeUpload'>;

  // the directory that holds each upload's file under its id
  readonly filesDir: string;
  readonly now: Date;
}

// Removes each upload whose expiry is before now, file then row, and returns their ids. A stopped
// sweep leaves a row the next one removes, never a file with no row, and each step is synchronous,
// so no API call runs between the two.
export function runExpirySweep(inputs: ExpirySweepInputs): readonly string[] {
  const ids = inputs.store.readExpiredIDs(inputs.now);

  for (const id of ids) {
    rmSync(join(inputs.filesDir, id), { force: true });

    inputs.store.removeUpload(id);
  }

  return ids;
}

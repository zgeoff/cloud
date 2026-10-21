import { rmSync } from 'node:fs';
import { join } from 'node:path';
import type { UploadStore } from './create-upload-store.ts';

interface ExpirySweepInputs {
  readonly store: Pick<UploadStore, 'readExpiredIDs' | 'removeUpload'>;
  readonly filesDir: string;
  readonly now: Date;
}

// file then row, so a stopped sweep leaves a row the next one removes, never a file with no row;
// each step is synchronous, so no API call runs between the two
export function runExpirySweep(inputs: ExpirySweepInputs): readonly string[] {
  const ids = inputs.store.readExpiredIDs(inputs.now);

  for (const id of ids) {
    rmSync(join(inputs.filesDir, id), { force: true });

    inputs.store.removeUpload(id);
  }

  return ids;
}

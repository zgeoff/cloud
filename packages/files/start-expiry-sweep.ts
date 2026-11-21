import type { Clock } from '@zgeoff/std';
import type { UploadStore } from './create-upload-store.ts';
import { runExpirySweep } from './run-expiry-sweep.ts';

const sweepIntervalMs = 60 * 60 * 1000;

interface ExpirySweepSchedule extends Pick<Clock, 'now'> {
  readonly store: Pick<UploadStore, 'readExpiredIDs' | 'removeUpload'>;
  readonly filesDir: string;
  readonly print: (line: string) => void;

  // runs run every intervalMs until the returned function stops it, as setInterval does
  readonly schedule: (run: () => void, intervalMs: number) => () => void;
}

export function startExpirySweep(inputs: ExpirySweepSchedule): () => void {
  const run = (): void => {
    const removed = runExpirySweep({
      store: inputs.store,
      filesDir: inputs.filesDir,
      now: new Date(inputs.now()),
    });

    inputs.print(`expiry sweep: removed ${removed.length} uploads`);
  };

  run();

  return inputs.schedule(run, sweepIntervalMs);
}

import type { UploadStore } from './create-upload-store.ts';
import { runExpirySweep } from './run-expiry-sweep.ts';

// how often the sweep runs after the one at start
const sweepIntervalMs = 60 * 60 * 1000;

interface ExpirySweepSchedule {
  readonly store: Pick<UploadStore, 'readExpiredIDs' | 'removeUpload'>;
  readonly filesDir: string;
  readonly now: () => Date;
  readonly print: (line: string) => void;

  // runs run every intervalMs until the returned function stops it, as setInterval does
  readonly schedule: (run: () => void, intervalMs: number) => () => void;
}

// Runs the expiry sweep once now, then every sweepIntervalMs, and returns the function that stops
// the schedule.
export function startExpirySweep(inputs: ExpirySweepSchedule): () => void {
  const run = (): void => {
    const removed = runExpirySweep({
      store: inputs.store,
      filesDir: inputs.filesDir,
      now: inputs.now(),
    });

    inputs.print(`expiry sweep: removed ${removed.length} uploads`);
  };

  run();

  return inputs.schedule(run, sweepIntervalMs);
}

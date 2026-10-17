import type { ReleaseRecord } from './release-registry.ts';

// every file that a bump of the record writes, sorted: each pin line's file and each lock file
export function collectPinFiles(record: ReleaseRecord): readonly string[] {
  const files = record.pins.flatMap((pin) => [
    ...pin.lines.map((line) => line.file),
    ...(pin.lock === undefined ? [] : [pin.lock.lockFile]),
  ]);

  return [...new Set(files)].toSorted();
}

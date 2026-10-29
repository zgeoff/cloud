import { pinTableFile } from './pin-table-file.ts';
import type { ReleaseRecord } from './release-registry.ts';

export function collectPinFiles(record: ReleaseRecord): readonly string[] {
  const files = record.pins.flatMap((pin) => [
    ...pin.lines.map((line) => line.file),
    ...(pin.lock === undefined ? [] : [pin.lock.lockFile]),
  ]);

  return [...new Set([...files, pinTableFile])].toSorted();
}

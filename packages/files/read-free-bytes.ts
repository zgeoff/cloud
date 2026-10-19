import { statfsSync } from 'node:fs';

// the bytes an unprivileged writer may still use on the filesystem that holds path
export function readFreeBytes(path: string): number {
  const stats = statfsSync(path);

  return stats.bavail * stats.bsize;
}

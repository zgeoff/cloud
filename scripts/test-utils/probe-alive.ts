import { readFileSync } from 'node:fs';
import { isProcessStatAlive } from './is-process-stat-alive.ts';

export function probeAlive(pid: number): boolean {
  try {
    return isProcessStatAlive(readFileSync(`/proc/${pid}/stat`, 'utf8'));
  } catch {
    return false;
  }
}

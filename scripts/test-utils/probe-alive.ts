import { readFileSync } from 'node:fs';

export function probeAlive(pid: number): boolean {
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, 'utf8');

    // an exited descendant stays a zombie until something reaps it, and a zombie holds no pipe
    return stat.slice(stat.lastIndexOf(')') + 2, stat.lastIndexOf(')') + 3) !== 'Z';
  } catch {
    return false;
  }
}

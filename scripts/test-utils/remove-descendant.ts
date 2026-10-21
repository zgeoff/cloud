import { readFile, rm } from 'node:fs/promises';

export async function removeDescendant(directory: string, pidFile: string): Promise<void> {
  const text = await readFile(pidFile, 'utf8').catch(() => '');

  const pid = Number(text);

  // a pid of 0 or below would signal this test's own process group
  if (Number.isInteger(pid) && pid > 0) {
    try {
      process.kill(pid, 'SIGKILL');
    } catch {
      // the descendant has exited
    }
  }

  await rm(directory, { recursive: true, force: true });
}

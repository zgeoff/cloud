import { probeAlive } from './probe-alive.ts';

export async function waitForExit(pid: number): Promise<boolean> {
  // the kernel closes a dying process's pipes a moment before it becomes a zombie, so this polls; a
  // second is long enough for a SIGKILL and far short of a test's sleep
  const deadline = performance.now() + 1000;

  // the answer is the last probe the loop made: a second read can see the process mid-way out
  let alive = probeAlive(pid);

  while (alive && performance.now() < deadline) {
    await Bun.sleep(5);

    alive = probeAlive(pid);
  }

  return !alive;
}

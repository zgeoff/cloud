import type { BoundedProcessDeps } from './run-bounded-process.ts';

export const processDeps: BoundedProcessDeps = {
  spawn: (argv, options) =>
    Bun.spawn([...argv], {
      ...(options.cwd === undefined ? {} : { cwd: options.cwd }),
      ...(options.env === undefined ? {} : { env: options.env }),
      stdin: 'ignore',
      stdout: 'pipe',
      stderr: 'pipe',

      // the child leads its own process group, so one kill reaches its grandchildren too
      detached: true,
    }),
  killGroup: (pid) => {
    process.kill(-pid, 'SIGKILL');
  },
  readGroup: async (pid) => {
    const listing = await Bun.$`ps -e -ww -o pid=,pgid=,ppid=,stat=,wchan:32=,args=`.quiet().text();

    return listing
      .split('\n')
      .filter((line) => line.trim().split(/\s+/u)[1] === String(pid))
      .map((line) => `${line.trim()}\n`)
      .join('');
  },
  sleep: (durationMs) => Bun.sleep(durationMs),
  now: () => performance.now(),
};

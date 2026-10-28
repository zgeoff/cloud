export interface PipedProcess {
  readonly stdout: ReadableStream<Uint8Array>;
  readonly stderr: ReadableStream<Uint8Array>;
  readonly kill: () => void;

  // the exit code, or 128 plus the signal's number for a process a signal ended
  readonly exited: Promise<number>;
}

export function spawnPiped(argv: readonly string[]): PipedProcess {
  const subprocess = Bun.spawn([...argv], { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' });

  return {
    stdout: subprocess.stdout,
    stderr: subprocess.stderr,
    kill: () => {
      subprocess.kill();
    },
    exited: subprocess.exited,
  };
}

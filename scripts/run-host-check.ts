// RunOptions carries stdin as a Buffer, which has no readonly form
/* oxlint-disable typescript/prefer-readonly-parameter-types */
import type { RunOptions, RunResult, Runner } from './run-process.ts';
import { toShellArg } from './to-shell-arg.ts';

// Runs one read-only command as root on the host, for a check that reads its exit code and output
// itself. The remote shell parses the command line, so each word is quoted as one; Tailscale SSH
// logs that line, so it never carries a secret.
export interface HostCheckIO {
  readonly run: Runner;

  // the host's tailnet name; the check signs in as root
  readonly host: string;
}

export function runHostCheck(
  io: Readonly<HostCheckIO>,
  remote: readonly string[],
  options: Readonly<RunOptions> = {},
): Promise<RunResult> {
  const command = remote.map((word) => toShellArg(word)).join(' ');

  const argv = [
    'ssh',
    '-o',
    'BatchMode=yes',
    '-o',
    'ConnectTimeout=15',
    `root@${io.host}`,
    command,
  ];

  return io.run(argv, { timeoutMs: 120_000, ...options });
}

import type { ScriptIO } from './run-or-exit.ts';
import { runOrExit } from './run-or-exit.ts';
import type { RunOptions, RunResult, Runner } from './run-process.ts';
import { toShellArg } from './to-shell-arg.ts';

// The scripts' one way to the host: root over a batch ssh with a connect timeout, 120 s per call
// by default, and each plain word quoted as one for the remote shell. Tailscale SSH logs the line
// and Alloy ships it to Loki, so the line never carries a secret: a secret goes in stdin.
export interface HostCheckIO {
  readonly run: Runner;

  // the host's tailnet name; the command signs in as root
  readonly host: string;
}

// Runs one read-only command, for a check that reads its exit code and output itself
export function runHostCheck(
  io: Readonly<HostCheckIO>,
  remote: readonly string[],
  options: Readonly<RunOptions> = {},
): Promise<RunResult> {
  return io.run(buildHostArgv(io.host, remote), { timeoutMs: hostTimeoutMs, ...options });
}

export interface HostIO extends HostCheckIO, ScriptIO {}

// Runs one command as a `set -e` line does and returns its stdout: its stderr passes through, and
// a failure stops the script with the command's exit code, or 124 for a timeout
export async function runOnHost(
  io: Readonly<HostIO>,
  remote: readonly string[],
  stdin?: Buffer,
): Promise<string> {
  const options = stdin === undefined ? {} : { stdin };

  const result = await runOrExit(io, buildHostArgv(io.host, remote), {
    timeoutMs: hostTimeoutMs,
    ...options,
  });

  return result.stdout.toString();
}

const hostTimeoutMs = 120_000;

function buildHostArgv(host: string, remote: readonly string[]): readonly string[] {
  const command = remote.map((word) => toShellArg(word)).join(' ');

  return ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', `root@${host}`, command];
}

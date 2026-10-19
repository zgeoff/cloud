import type { ScriptIO } from './run-or-exit.ts';
import { runOrExit } from './run-or-exit.ts';
import type { RunOptions, RunResult, Runner } from './run-process.ts';
import { toShellArg } from './to-shell-arg.ts';

export interface HostCheckIO {
  readonly run: Runner;

  readonly host: string;
}

export function runHostCheck(
  io: Readonly<HostCheckIO>,
  remote: readonly string[],
  options: Readonly<RunOptions> = {},
): Promise<RunResult> {
  return io.run(buildHostArgv(io.host, remote), { timeoutMs: hostTimeoutMs, ...options });
}

export interface HostIO extends HostCheckIO, ScriptIO {}

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
  // Tailscale SSH logs the line and Alloy ships it to Loki, so a secret goes in stdin, never here
  const command = remote.map((word) => toShellArg(word)).join(' ');

  return ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', `root@${host}`, command];
}

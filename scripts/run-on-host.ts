import type { ScriptIO } from './run-or-exit.ts';
import { runOrExit } from './run-or-exit.ts';

export interface HostIO extends ScriptIO {
  // the ssh destination, such as root@geoffcloud
  readonly host: string;
}

// Runs one command line as root on the host and returns its stdout. Tailscale SSH logs the line
// and Alloy ships that log to Loki, so the line never carries a secret: a secret goes in stdin.
export async function runOnHost(
  io: Readonly<HostIO>,
  remote: readonly string[],
  stdin?: Buffer,
): Promise<string> {
  const options = stdin === undefined ? {} : { stdin };

  const result = await runOrExit(io, ['ssh', '-o', 'BatchMode=yes', io.host, ...remote], options);

  return result.stdout.toString();
}

import type { ReadinessLine } from './format-readiness-line.ts';
import type { HostCheckIO } from './run-host-check.ts';
import { runHostCheck } from './run-host-check.ts';

// the cloud daemon on the host, which the gateway's sessions reach
export async function checkATCDaemon(io: Readonly<HostCheckIO>): Promise<ReadinessLine> {
  const result = await runHostCheck(io, ['systemctl', 'is-active', '--quiet', 'atc-daemon']);

  return result.exitCode === 0
    ? { status: 'ok', text: `atc-daemon is active on ${io.host}` }
    : { status: 'missing', text: `atc-daemon service on ${io.host}` };
}

import { parseJSONOutput } from './parse-json-output.ts';
import type { HostIO } from './run-on-host.ts';
import { runOnHost } from './run-on-host.ts';

// Reads impd's secrets or tokens through the impz CLI in the host's imp-host container. A stopped
// container fails the run with docker's own message.
export async function readImpList(
  io: Readonly<HostIO>,
  kind: 'secret' | 'token',
): Promise<unknown> {
  const text = await runOnHost(io, ['docker', 'exec', 'imp-host', 'impz', kind, 'ls', '--json']);

  return parseJSONOutput(text, `impz ${kind} ls`);
}

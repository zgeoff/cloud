import { exposure } from '@zgeoff/cloud-topology';
import { buildExactPathPattern } from './build-exact-path-pattern.ts';
import { buildTunnelIngresses } from './build-tunnel-ingresses.ts';
import type { TunnelIngress } from './build-tunnel-ingresses.ts';
import { impdMCPPaths } from './impd-mcp-paths.ts';

// the connector runs on the host, where imp-host publishes impd's public listener on loopback
// alone. No Access login fronts the sign-in pages: impd checks the owner's passkey itself, and the
// pages were open to the internet before the tunnel.
export function buildImpdMCPIngresses(hostname: string): TunnelIngress[] {
  const listener = exposure.entries.find((entry) => entry.name === 'impd-mcp-listener');

  if (listener?.kind !== 'host-port' || listener.port === undefined) {
    throw new Error('the exposure registry has no impd-mcp-listener entry with a port');
  }

  return buildTunnelIngresses([
    {
      hostname,
      service: `http://127.0.0.1:${String(listener.port)}`,
      path: buildExactPathPattern(impdMCPPaths),
    },
  ]);
}

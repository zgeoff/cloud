import { topology } from '@zgeoff/cloud-topology';
import { boxxyDoorPaths } from './boxxy-door-paths.ts';
import { buildSignInRoutes } from './build-sign-in-routes.ts';
import type { OriginAccess, TunnelIngress } from './build-tunnel-ingresses.ts';
import { buildTunnelIngresses } from './build-tunnel-ingresses.ts';

// the door listens on the pod's loopback alone, where only the tunnel's sidecar reaches it
export function buildBoxxyDoorIngresses(hostname: string, access: OriginAccess): TunnelIngress[] {
  const service = `http://127.0.0.1:${String(topology.boxxy.doorPort)}`;

  return buildTunnelIngresses(buildSignInRoutes({ hostname, service }, boxxyDoorPaths, access));
}

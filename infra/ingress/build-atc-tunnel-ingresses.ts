import { topology } from '@zgeoff/cloud-topology';
import { atcGatewayPaths } from './atc-gateway-paths.ts';
import { buildSignInRoutes } from './build-sign-in-routes.ts';
import type { OriginAccess, TunnelIngress } from './build-tunnel-ingresses.ts';
import { buildTunnelIngresses } from './build-tunnel-ingresses.ts';

export function buildATCTunnelIngresses(hostname: string, access: OriginAccess): TunnelIngress[] {
  const service = `http://127.0.0.1:${String(topology.atc.gatewayPort)}`;

  return buildTunnelIngresses(buildSignInRoutes({ hostname, service }, atcGatewayPaths, access));
}

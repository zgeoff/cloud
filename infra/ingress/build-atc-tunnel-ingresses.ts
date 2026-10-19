import { topology } from '@zgeoff/cloud-topology';
import { buildATCGatewayRoutes } from './build-atc-gateway-routes.ts';
import type { OriginAccess, TunnelIngress } from './build-tunnel-ingresses.ts';
import { buildTunnelIngresses } from './build-tunnel-ingresses.ts';

export function buildATCTunnelIngresses(hostname: string, access: OriginAccess): TunnelIngress[] {
  const service = `http://127.0.0.1:${String(topology.atc.gatewayPort)}`;

  return buildTunnelIngresses(buildATCGatewayRoutes({ hostname, service }, access));
}

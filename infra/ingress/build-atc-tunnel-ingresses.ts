import { topology } from '@zgeoff/cloud-topology';
import { buildATCGatewayRoutes } from './build-atc-gateway-routes.ts';
import type { OriginAccess, TunnelIngress } from './build-tunnel-ingresses.ts';
import { buildTunnelIngresses } from './build-tunnel-ingresses.ts';

// the gateway on its pod's loopback, where its cloudflared sidecar reaches it
const sidecarOrigin = `http://127.0.0.1:${String(topology.atc.gatewayPort)}`;

// The atc tunnel's ingress rules: the gateway's routes as the shared tunnel serves them, Access
// check and catch-all 404 included, with the pod's loopback as the origin.
export function buildATCTunnelIngresses(hostname: string, access: OriginAccess): TunnelIngress[] {
  return buildTunnelIngresses(buildATCGatewayRoutes({ hostname, service: sidecarOrigin }, access));
}

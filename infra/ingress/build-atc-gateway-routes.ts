import { atcGatewayPaths } from './atc-gateway-paths.ts';
import { buildExactPathPattern } from './build-exact-path-pattern.ts';
import type { OriginAccess, TunnelRoute } from './build-tunnel-ingresses.ts';

export function buildATCGatewayRoutes(route: TunnelRoute, access: OriginAccess): TunnelRoute[] {
  return [
    {
      hostname: route.hostname,
      service: route.service,
      path: buildExactPathPattern(atcGatewayPaths.browser),
      access,
    },
    {
      hostname: route.hostname,
      service: route.service,
      path: buildExactPathPattern(atcGatewayPaths.machine),
    },
  ];
}

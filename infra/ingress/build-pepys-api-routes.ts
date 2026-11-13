import { buildExactPathPattern } from './build-exact-path-pattern.ts';
import type { OriginAccess, TunnelRoute } from './build-tunnel-ingresses.ts';
import { pepysAPIPaths } from './pepys-api-paths.ts';

// /rpc is in neither list, so the tunnel answers it with the catch-all's 404
export function buildPepysAPIRoutes(route: TunnelRoute, access: OriginAccess): TunnelRoute[] {
  return [
    {
      hostname: route.hostname,
      service: route.service,
      path: buildExactPathPattern(pepysAPIPaths.browser),
      access,
    },
    {
      hostname: route.hostname,
      service: route.service,
      path: buildExactPathPattern(pepysAPIPaths.machine),
    },
  ];
}

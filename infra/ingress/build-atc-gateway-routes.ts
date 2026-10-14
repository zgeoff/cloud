import { atcGatewayPaths } from './atc-gateway-paths.ts';
import type { OriginAccess, TunnelRoute } from './build-tunnel-ingresses.ts';

// The atc gateway's two tunnel routes: its browser paths behind cloudflared's own check of the
// Access token, then its machine paths with none. Each pattern matches whole paths only, so any
// other path, `/login/` or `/LOGIN` among them, falls through to the catch-all 404.
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

// both anchors, with every metacharacter escaped
function buildExactPathPattern(paths: readonly string[]): string {
  return `^(?:${paths.map((path) => path.replaceAll(/[$()*+.?[\\\]^{|}]/gu, String.raw`\$&`)).join('|')})$`;
}

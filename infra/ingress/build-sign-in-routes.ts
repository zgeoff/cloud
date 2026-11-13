import { buildExactPathPattern } from './build-exact-path-pattern.ts';
import type { OriginAccess, TunnelRoute } from './build-tunnel-ingresses.ts';

// a workload's routes split by caller: the pages the owner's browser loads, and the paths that an
// MCP client calls with no browser
export interface SignInPaths {
  readonly browser: readonly string[];
  readonly machine: readonly string[];
}

export function buildSignInRoutes(
  route: TunnelRoute,
  paths: SignInPaths,
  access: OriginAccess,
): TunnelRoute[] {
  return [
    {
      hostname: route.hostname,
      service: route.service,
      path: buildExactPathPattern(paths.browser),
      access,
    },
    {
      hostname: route.hostname,
      service: route.service,
      path: buildExactPathPattern(paths.machine),
    },
  ];
}

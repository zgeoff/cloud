import type { Output } from '@pulumi/pulumi';
import { exposure } from '@zgeoff/cloud-topology';

// a public hostname the tunnel serves, from a workload in k3s or a listener on the host, and the
// one path it lets through when it lets through only one: a Go regular expression that cloudflared
// matches anywhere in the request path, so it needs both anchors
export interface TunnelRoute {
  readonly hostname: string;
  readonly service: string | Output<string>;
  readonly path?: string;
}

interface TunnelIngress {
  readonly hostname?: string;
  readonly path?: string;
  readonly service: string | Output<string>;
}

// The tunnel's ingress rules, then the catch-all 404, last since cloudflared takes the first rule
// that matches; a route's hostname on another path falls through to it. A hostname without a
// public entry in the exposure registry fails the preview instead of going public.
export function buildTunnelIngresses(routes: readonly TunnelRoute[]): TunnelIngress[] {
  for (const route of routes) {
    requirePublicTunnelHostname(route.hostname);
  }

  return [
    ...routes.map((route) => ({
      hostname: route.hostname,
      ...(route.path === undefined ? {} : { path: route.path }),
      service: route.service,
    })),
    { service: 'http_status:404' },
  ];
}

function requirePublicTunnelHostname(hostname: string): void {
  const entry = exposure.entries.find(
    (candidate) => candidate.kind === 'tunnel-hostname' && candidate.hostname === hostname,
  );

  if (entry?.scope !== 'public') {
    throw new Error(
      `tunnel hostname ${hostname} is ${entry === undefined ? 'not in' : `${entry.scope} in`} ` +
        'packages/topology/exposure.json; a route needs a public tunnel-hostname entry',
    );
  }
}

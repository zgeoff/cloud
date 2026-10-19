import type { Output } from '@pulumi/pulumi';
import { exposure } from '@zgeoff/cloud-topology';

// a public hostname the tunnel serves, from a workload in k3s or a listener on the host, and the
// paths it lets through when it limits them: a Go regular expression that cloudflared matches
// anywhere in the decoded request path, so it needs both anchors
export interface TunnelRoute {
  readonly hostname: string;
  readonly service: string | Output<string>;
  readonly path?: string;

  // the Access application whose token cloudflared requires on this route
  readonly access?: OriginAccess;
}

// the Access application whose token cloudflared checks on a route
export interface OriginAccess {
  readonly teamName: Output<string>;
  readonly audience: Output<string>;
}

// one of a tunnel's ingress rules, as ZeroTrustTunnelCloudflaredConfig takes it
export interface TunnelIngress {
  readonly hostname?: string;
  readonly path?: string;
  readonly service: string | Output<string>;
  readonly originRequest?: {
    readonly access: {
      readonly required: boolean;
      readonly teamName: Output<string>;
      readonly audTags: Output<string>[];
    };
  };
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
      ...(route.access === undefined
        ? {}
        : {
            originRequest: {
              access: {
                required: true,
                teamName: route.access.teamName,
                audTags: [route.access.audience],
              },
            },
          }),
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

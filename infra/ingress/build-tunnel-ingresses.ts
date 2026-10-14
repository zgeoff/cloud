import type { Output } from '@pulumi/pulumi';
import { exposure } from '@zgeoff/cloud-topology';
import { atcGatewayPaths } from './atc-gateway-paths.ts';

// a public hostname the tunnel serves from a workload in k3s
export interface TunnelRoute {
  readonly hostname: string;
  readonly service: Output<string>;
}

// the Access application whose token cloudflared checks on a route's browser paths
export interface OriginAccess {
  readonly teamName: Output<string>;
  readonly audience: Output<string>;
}

// the atc gateway's route and the Access application in front of its sign-in pages
export interface GatewayIngress {
  readonly route: TunnelRoute;
  readonly access: OriginAccess;
}

interface TunnelIngress {
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

// The tunnel's ingress rules, in cloudflared's first-match order: the gateway's browser paths behind
// cloudflared's own Access token check, its machine paths, then the catch-all 404 (public-ingress.md
// in docs/architecture/network). An unlisted hostname fails the preview instead of going public.
export function buildTunnelIngresses(gateway: GatewayIngress | undefined): TunnelIngress[] {
  if (gateway === undefined) {
    return [{ service: 'http_status:404' }];
  }

  const route = gateway.route;
  const access = gateway.access;

  requirePublicTunnelHostname(route.hostname);

  return [
    {
      hostname: route.hostname,
      path: buildExactPathPattern(atcGatewayPaths.browser),
      service: route.service,
      originRequest: {
        access: { required: true, teamName: access.teamName, audTags: [access.audience] },
      },
    },
    {
      hostname: route.hostname,
      path: buildExactPathPattern(atcGatewayPaths.machine),
      service: route.service,
    },
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

// cloudflared matches a rule's path as a Go regular expression against the request's decoded
// path, so the pattern anchors both ends and escapes every metacharacter
function buildExactPathPattern(paths: readonly string[]): string {
  return `^(?:${paths.map((path) => path.replaceAll(/[$()*+.?[\\\]^{|}]/gu, String.raw`\$&`)).join('|')})$`;
}

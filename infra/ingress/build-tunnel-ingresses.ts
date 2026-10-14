import type { Output } from '@pulumi/pulumi';
import { exposure } from '@zgeoff/cloud-topology';

// a public hostname the tunnel serves from a workload in k3s
export interface TunnelRoute {
  readonly hostname: string;
  readonly service: Output<string>;
}

interface TunnelIngress {
  readonly hostname?: string;
  readonly service: string | Output<string>;
}

// The tunnel's ingress rules: each route's hostname to its service, then the catch-all 404, last
// since cloudflared takes the first rule that matches. A hostname without a public entry in the
// exposure registry, a reserved one included, fails the preview instead of going public.
export function buildTunnelIngresses(atcRoute: TunnelRoute | undefined): TunnelIngress[] {
  if (atcRoute !== undefined) {
    requirePublicTunnelHostname(atcRoute.hostname);
  }

  return [
    ...(atcRoute === undefined ? [] : [{ hostname: atcRoute.hostname, service: atcRoute.service }]),
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

import type { Output } from '@pulumi/pulumi';

// a public hostname the tunnel serves from a workload in k3s
export interface TunnelRoute {
  readonly hostname: string;
  readonly service: Output<string>;
}

interface TunnelIngress {
  readonly hostname?: string;
  readonly service: string | Output<string>;
}

// The tunnel's ingress rules: each route's hostname to its service, then the catch-all
// 404, which stays last, since cloudflared takes the first rule that matches
export function buildTunnelIngresses(atcRoute: TunnelRoute | undefined): TunnelIngress[] {
  return [
    ...(atcRoute === undefined ? [] : [{ hostname: atcRoute.hostname, service: atcRoute.service }]),
    { service: 'http_status:404' },
  ];
}

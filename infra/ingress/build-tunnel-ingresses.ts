import type { Output } from '@pulumi/pulumi';
import { exposure } from '@zgeoff/cloud-topology';
import type { ExposureEntry } from '@zgeoff/cloud-topology';

export interface OriginAccess {
  readonly teamName: Output<string>;
  readonly audience: Output<string>;
}

export interface TunnelRoute {
  readonly hostname: string;
  readonly service: string | Output<string>;

  // a Go regular expression that cloudflared matches anywhere in the decoded request path, so it
  // needs both anchors
  readonly path?: string;

  readonly access?: OriginAccess;
}

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

    // last, since cloudflared takes the first rule that matches
    { service: 'http_status:404' },
  ];
}

function requirePublicTunnelHostname(hostname: string): void {
  const entry = exposure.entries.find(
    (candidate) => 'hostname' in candidate && candidate.hostname === hostname,
  );

  if (entry?.kind !== 'tunnel-hostname' || entry.scope !== 'public') {
    throw new Error(
      `tunnel hostname ${hostname} is ${formatListing(entry)} ` +
        'packages/topology/exposure.json; a route needs a public tunnel-hostname entry',
    );
  }
}

function formatListing(entry: ExposureEntry | undefined): string {
  if (entry === undefined) {
    return 'not in';
  }

  return entry.kind === 'tunnel-hostname' ? `${entry.scope} in` : `a ${entry.kind} entry in`;
}

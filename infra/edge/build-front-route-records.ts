import type { Output } from '@pulumi/pulumi';
import type { ExposureEntry } from '@zgeoff/cloud-topology';

interface FrontRouteRecordsInputs {
  readonly entries: readonly ExposureEntry[];
  readonly zoneID: Output<string>;
  readonly ipv4: string;
  readonly ipv6: string;
}

interface FrontRouteRecord {
  readonly name: string;
  readonly args: {
    readonly zoneId: Output<string>;
    readonly name: string;
    readonly type: 'A' | 'AAAA';
    readonly content: string;
    readonly proxied: false;
    readonly ttl: 1;
  };
}

// DNS only: the host's TLS front terminates TLS and gets its certificate by TLS-ALPN-01 itself,
// and Cloudflare's proxy would cut an MCP event stream that stays idle past its read timeout
export function buildFrontRouteRecords(
  inputs: FrontRouteRecordsInputs,
): readonly FrontRouteRecord[] {
  return inputs.entries.flatMap((entry) =>
    entry.kind === 'front-route' && entry.scope === 'public'
      ? [
          {
            name: `front-${entry.name}-v4`,
            args: {
              zoneId: inputs.zoneID,
              name: entry.hostname,
              type: 'A' as const,
              content: inputs.ipv4,
              proxied: false as const,
              ttl: 1 as const,
            },
          },
          {
            name: `front-${entry.name}-v6`,
            args: {
              zoneId: inputs.zoneID,
              name: entry.hostname,
              type: 'AAAA' as const,
              content: inputs.ipv6,
              proxied: false as const,
              ttl: 1 as const,
            },
          },
        ]
      : [],
  );
}

import { DnsRecord, ZeroTrustTunnelCloudflaredConfig } from '@pulumi/cloudflare';
import type { Output } from '@pulumi/pulumi';
import { buildTunnelIngresses } from './build-tunnel-ingresses.ts';
import type { TunnelRoute } from './build-tunnel-ingresses.ts';

interface TunnelRoutesInputs {
  readonly accountID: string;
  readonly zoneID: Output<string>;
  readonly tunnelID: Output<string>;

  // the atc gateway, on its public URL's host. It owns OAuth too.
  readonly atcRoute?: TunnelRoute | undefined;
}

interface TunnelRoutesOutputs {
  readonly configVersion: Output<number>;
  readonly atcURL?: Output<string>;
}

// The tunnel's ingress rules and the proxied CNAME for each hostname. The catch-all 404
// stays last.
export function createTunnelRoutes(inputs: TunnelRoutesInputs): TunnelRoutesOutputs {
  const atcRoute = inputs.atcRoute;

  const config = new ZeroTrustTunnelCloudflaredConfig('edge', {
    accountId: inputs.accountID,
    tunnelId: inputs.tunnelID,
    config: {
      ingresses: buildTunnelIngresses(atcRoute),
    },
  });

  const atc = atcRoute === undefined ? undefined : createRecord('atc', inputs, atcRoute.hostname);

  return {
    configVersion: config.version,
    ...(atc === undefined ? {} : { atcURL: toURL(atc) }),
  };
}

function createRecord(name: string, inputs: TunnelRoutesInputs, hostname: string): DnsRecord {
  return new DnsRecord(name, {
    zoneId: inputs.zoneID,
    name: hostname,
    type: 'CNAME',
    content: inputs.tunnelID.apply((id) => `${id}.cfargotunnel.com`),
    proxied: true,
    ttl: 1,
  });
}

function toURL(record: DnsRecord): Output<string> {
  return record.name.apply((name) => `https://${name}`);
}

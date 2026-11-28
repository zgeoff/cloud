import {
  ZeroTrustTunnelCloudflared,
  getZeroTrustTunnelCloudflaredTokenOutput,
} from '@pulumi/cloudflare';
import type { Output } from '@pulumi/pulumi';
import { secret } from '@pulumi/pulumi';

export interface SidecarTunnel {
  readonly tunnelID: Output<string>;
  readonly tunnelToken: Output<string>;
}

interface SidecarTunnelNames {
  // the Pulumi resource name, which the tunnel's URN holds
  readonly resourceName: string;

  // the tunnel's name in Cloudflare
  readonly tunnelName: string;
}

export function createSidecarTunnel(accountID: string, names: SidecarTunnelNames): SidecarTunnel {
  // A tunnel of its own: its connector runs beside the workload, as a sidecar in its pod or as a
  // service on the host, so the workload can trust the forwarded client address on loopback, where
  // only that connector reaches it.
  const tunnel = new ZeroTrustTunnelCloudflared(names.resourceName, {
    accountId: accountID,
    name: names.tunnelName,
    configSrc: 'cloudflare',
  });

  return {
    tunnelID: tunnel.id,
    tunnelToken: secret(
      getZeroTrustTunnelCloudflaredTokenOutput({ accountId: accountID, tunnelId: tunnel.id }).token,
    ),
  };
}

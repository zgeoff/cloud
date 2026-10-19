import {
  ZeroTrustTunnelCloudflared,
  getZeroTrustTunnelCloudflaredTokenOutput,
} from '@pulumi/cloudflare';
import type { Output } from '@pulumi/pulumi';
import { secret } from '@pulumi/pulumi';

export interface ATCTunnel {
  readonly tunnelID: Output<string>;
  readonly tunnelToken: Output<string>;
}

export function createATCTunnel(accountID: string): ATCTunnel {
  // A tunnel of its own: its connector runs as a sidecar in the gateway pod, so the gateway can
  // trust the forwarded client address on loopback, where only that connector reaches it.
  const tunnel = new ZeroTrustTunnelCloudflared('atc', {
    accountId: accountID,
    name: 'geoff-cloud-atc',
    configSrc: 'cloudflare',
  });

  return {
    tunnelID: tunnel.id,
    tunnelToken: secret(
      getZeroTrustTunnelCloudflaredTokenOutput({ accountId: accountID, tunnelId: tunnel.id }).token,
    ),
  };
}

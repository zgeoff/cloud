import {
  ZeroTrustTunnelCloudflared,
  getZeroTrustTunnelCloudflaredTokenOutput,
} from '@pulumi/cloudflare';
import type { Output } from '@pulumi/pulumi';
import { secret } from '@pulumi/pulumi';

// the atc tunnel's ID, for its routes and its CNAME, and its connector's token
export interface ATCTunnel {
  readonly tunnelID: Output<string>;
  readonly tunnelToken: Output<string>;
}

// The tunnel for atc.geoff.cloud alone (GEO-1388). Its connector runs as a sidecar in the gateway
// pod, so the gateway can trust the forwarded client address on loopback, where only that
// connector reaches it. createIngress renders its routes.
export function createATCTunnel(accountID: string): ATCTunnel {
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

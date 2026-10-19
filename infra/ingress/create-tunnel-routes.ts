import { DnsRecord, ZeroTrustTunnelCloudflaredConfig } from '@pulumi/cloudflare';
import type { Output } from '@pulumi/pulumi';
import { buildATCGatewayRoutes } from './build-atc-gateway-routes.ts';
import { buildATCTunnelIngresses } from './build-atc-tunnel-ingresses.ts';
import { buildPreviewWebhookRoute } from './build-preview-webhook-route.ts';
import { buildTunnelIngresses } from './build-tunnel-ingresses.ts';
import type { OriginAccess, TunnelRoute } from './build-tunnel-ingresses.ts';

interface TunnelRoutesInputs {
  readonly accountID: string;
  readonly zoneID: Output<string>;
  readonly tunnelID: Output<string>;

  // the atc gateway, on its public URL's host, with the Access application in front of its
  // sign-in pages. It owns OAuth too.
  readonly gateway?: GatewayIngress | undefined;
}

// the atc gateway's route, the Access application in front of its sign-in pages, and the atc
// tunnel, whose connector runs in the gateway's pod
export interface GatewayIngress {
  readonly route: TunnelRoute;
  readonly access: OriginAccess;
  readonly tunnelID: Output<string>;
}

interface TunnelRoutesOutputs {
  readonly configVersion: Output<number>;
  readonly atcConfigVersion?: Output<number>;
  readonly atcURL?: Output<string>;

  // the payload URL each opted-in repository's webhook posts to
  readonly previewWebhookURL: Output<string>;
}

// The tunnel's ingress rules and the proxied CNAME for each hostname. The catch-all 404
// stays last.
export function createTunnelRoutes(inputs: TunnelRoutesInputs): TunnelRoutesOutputs {
  const gateway = inputs.gateway;
  const previewWebhookRoute = buildPreviewWebhookRoute();

  const config = new ZeroTrustTunnelCloudflaredConfig('edge', {
    accountId: inputs.accountID,
    tunnelId: inputs.tunnelID,
    config: {
      ingresses: buildTunnelIngresses([
        ...(gateway === undefined ? [] : buildATCGatewayRoutes(gateway.route, gateway.access)),
        previewWebhookRoute,
      ]),
    },
  });

  // the atc tunnel's own rules, which serve nothing while the gateway's CNAME points at this tunnel
  const atcConfig =
    gateway === undefined
      ? undefined
      : new ZeroTrustTunnelCloudflaredConfig('atc', {
          accountId: inputs.accountID,
          tunnelId: gateway.tunnelID,
          config: { ingresses: buildATCTunnelIngresses(gateway.route.hostname, gateway.access) },
        });

  const atc =
    gateway === undefined ? undefined : createRecord('atc', inputs, gateway.route.hostname);

  const previewWebhook = createRecord('preview-webhook', inputs, previewWebhookRoute.hostname);

  return {
    configVersion: config.version,
    ...(atcConfig === undefined ? {} : { atcConfigVersion: atcConfig.version }),
    ...(atc === undefined ? {} : { atcURL: toURL(atc) }),
    previewWebhookURL: toURL(previewWebhook).apply((url) => `${url}/webhook`),
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

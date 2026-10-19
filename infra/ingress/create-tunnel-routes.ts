import { DnsRecord, ZeroTrustTunnelCloudflaredConfig } from '@pulumi/cloudflare';
import type { Output } from '@pulumi/pulumi';
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

// Each tunnel's ingress rules and the proxied CNAME for each hostname: the gateway's on the atc
// tunnel, the preview webhook's on the shared one. Each tunnel's catch-all 404 stays last.
export function createTunnelRoutes(inputs: TunnelRoutesInputs): TunnelRoutesOutputs {
  const gateway = inputs.gateway;
  const previewWebhookRoute = buildPreviewWebhookRoute();
  const atc = gateway === undefined ? undefined : createATCRoutes(inputs, gateway);

  // after the gateway's CNAME, so a hostname the shared tunnel drops already points elsewhere
  const config = new ZeroTrustTunnelCloudflaredConfig(
    'edge',
    {
      accountId: inputs.accountID,
      tunnelId: inputs.tunnelID,
      config: { ingresses: buildTunnelIngresses([previewWebhookRoute]) },
    },
    { dependsOn: atc === undefined ? [] : [atc.record] },
  );

  const previewWebhook = createRecord(
    'preview-webhook',
    inputs.zoneID,
    previewWebhookRoute.hostname,
    inputs.tunnelID,
  );

  return {
    configVersion: config.version,
    ...(atc === undefined
      ? {}
      : { atcConfigVersion: atc.config.version, atcURL: toURL(atc.record) }),
    previewWebhookURL: toURL(previewWebhook).apply((url) => `${url}/webhook`),
  };
}

// the atc tunnel's rules and the gateway's CNAME to that tunnel
function createATCRoutes(
  inputs: TunnelRoutesInputs,
  gateway: GatewayIngress,
): { readonly config: ZeroTrustTunnelCloudflaredConfig; readonly record: DnsRecord } {
  const config = new ZeroTrustTunnelCloudflaredConfig('atc', {
    accountId: inputs.accountID,
    tunnelId: gateway.tunnelID,
    config: { ingresses: buildATCTunnelIngresses(gateway.route.hostname, gateway.access) },
  });

  return {
    config,
    record: createRecord('atc', inputs.zoneID, gateway.route.hostname, gateway.tunnelID),
  };
}

function createRecord(
  name: string,
  zoneID: Output<string>,
  hostname: string,
  tunnelID: Output<string>,
): DnsRecord {
  return new DnsRecord(name, {
    zoneId: zoneID,
    name: hostname,
    type: 'CNAME',
    content: tunnelID.apply((id) => `${id}.cfargotunnel.com`),
    proxied: true,
    ttl: 1,
  });
}

function toURL(record: DnsRecord): Output<string> {
  return record.name.apply((name) => `https://${name}`);
}

import { DnsRecord, ZeroTrustTunnelCloudflaredConfig } from '@pulumi/cloudflare';
import type { Output } from '@pulumi/pulumi';
import { buildTunnelRouteSpecs } from './build-tunnel-route-specs.ts';
import type { GatewayIngress, TunnelRecordSpec } from './build-tunnel-route-specs.ts';

interface TunnelRoutesInputs {
  readonly accountID: string;
  readonly zoneID: Output<string>;
  readonly tunnelID: Output<string>;

  // the atc gateway, on its public URL's host, with the Access application in front of its
  // sign-in pages. It owns OAuth too.
  readonly gateway?: GatewayIngress | undefined;
}

interface TunnelRoutesOutputs {
  readonly configVersion: Output<number>;
  readonly atcConfigVersion?: Output<number>;
  readonly atcURL?: Output<string>;

  // the payload URL each opted-in repository's webhook posts to
  readonly previewWebhookURL: Output<string>;
}

// Each tunnel's ingress rules and the proxied CNAME for each hostname, as buildTunnelRouteSpecs
// assigns them. Each tunnel's catch-all 404 stays last.
export function createTunnelRoutes(inputs: TunnelRoutesInputs): TunnelRoutesOutputs {
  const specs = buildTunnelRouteSpecs(inputs.tunnelID, inputs.gateway);

  const atc =
    specs.atc === undefined
      ? undefined
      : {
          config: new ZeroTrustTunnelCloudflaredConfig('atc', {
            accountId: inputs.accountID,
            tunnelId: specs.atc.record.tunnelID,
            config: { ingresses: specs.atc.ingresses },
          }),
          record: createRecord('atc', inputs.zoneID, specs.atc.record),
        };

  // after the gateway's CNAME, so a hostname the shared tunnel drops already points elsewhere; a
  // failed CNAME update stops the apply before the shared tunnel drops the gateway's rules
  const config = new ZeroTrustTunnelCloudflaredConfig(
    'edge',
    {
      accountId: inputs.accountID,
      tunnelId: inputs.tunnelID,
      config: { ingresses: specs.sharedIngresses },
    },
    { dependsOn: atc === undefined ? [] : [atc.record] },
  );

  const previewWebhook = createRecord('preview-webhook', inputs.zoneID, specs.previewWebhookRecord);

  return {
    configVersion: config.version,
    ...(atc === undefined
      ? {}
      : { atcConfigVersion: atc.config.version, atcURL: toURL(atc.record) }),
    previewWebhookURL: toURL(previewWebhook).apply((url) => `${url}/webhook`),
  };
}

function createRecord(name: string, zoneID: Output<string>, spec: TunnelRecordSpec): DnsRecord {
  return new DnsRecord(name, {
    zoneId: zoneID,
    name: spec.hostname,
    type: 'CNAME',
    content: spec.tunnelID.apply((id) => `${id}.cfargotunnel.com`),
    proxied: true,
    ttl: 1,
  });
}

function toURL(record: DnsRecord): Output<string> {
  return record.name.apply((name) => `https://${name}`);
}

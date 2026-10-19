import type { Output } from '@pulumi/pulumi';
import { buildATCTunnelIngresses } from './build-atc-tunnel-ingresses.ts';
import { buildPreviewWebhookRoute } from './build-preview-webhook-route.ts';
import { buildTunnelIngresses } from './build-tunnel-ingresses.ts';
import type { OriginAccess, TunnelIngress, TunnelRoute } from './build-tunnel-ingresses.ts';

// the atc gateway's public host, the Access application in front of its sign-in pages, and the
// atc tunnel, whose connector runs in the gateway's pod and reaches it on loopback
export interface GatewayIngress {
  readonly hostname: string;
  readonly access: OriginAccess;
  readonly tunnelID: Output<string>;
}

// a proxied CNAME from hostname to the tunnel that serves it
export interface TunnelRecordSpec {
  readonly hostname: string;
  readonly tunnelID: Output<string>;
}

export interface TunnelRouteSpecs {
  readonly sharedIngresses: TunnelIngress[];
  readonly previewWebhookRecord: TunnelRecordSpec;
  readonly filesRecord?: TunnelRecordSpec;
  readonly atc?: { readonly ingresses: TunnelIngress[]; readonly record: TunnelRecordSpec };
}

// Which tunnel serves each public hostname: the shared one the preview webhook and the files
// service, and the atc tunnel the gateway's hostname, with each hostname's CNAME to the tunnel
// that serves it.
export function buildTunnelRouteSpecs(
  sharedTunnelID: Output<string>,
  gateway: GatewayIngress | undefined,
  files: TunnelRoute | undefined,
): TunnelRouteSpecs {
  const previewWebhookRoute = buildPreviewWebhookRoute();

  return {
    sharedIngresses: buildTunnelIngresses([
      previewWebhookRoute,
      ...(files === undefined ? [] : [files]),
    ]),
    previewWebhookRecord: { hostname: previewWebhookRoute.hostname, tunnelID: sharedTunnelID },
    ...(files === undefined
      ? {}
      : { filesRecord: { hostname: files.hostname, tunnelID: sharedTunnelID } }),
    ...(gateway === undefined
      ? {}
      : {
          atc: {
            ingresses: buildATCTunnelIngresses(gateway.hostname, gateway.access),
            record: { hostname: gateway.hostname, tunnelID: gateway.tunnelID },
          },
        }),
  };
}

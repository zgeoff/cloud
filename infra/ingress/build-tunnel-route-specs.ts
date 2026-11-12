import type { Output } from '@pulumi/pulumi';
import { buildATCTunnelIngresses } from './build-atc-tunnel-ingresses.ts';
import { buildBoxxyDoorIngresses } from './build-boxxy-door-ingresses.ts';
import { buildPreviewWebhookRoute } from './build-preview-webhook-route.ts';
import { buildTunnelIngresses } from './build-tunnel-ingresses.ts';
import type { OriginAccess, TunnelIngress, TunnelRoute } from './build-tunnel-ingresses.ts';

// a hostname on a tunnel of its own, whose connector is a sidecar in the workload's pod
export interface GatewayIngress {
  readonly hostname: string;
  readonly access: OriginAccess;
  readonly tunnelID: Output<string>;
}

export interface TunnelRecordSpec {
  readonly hostname: string;
  readonly tunnelID: Output<string>;
}

interface SidecarTunnelSpec {
  readonly ingresses: TunnelIngress[];
  readonly record: TunnelRecordSpec;
}

export interface TunnelRouteSpecs {
  readonly sharedIngresses: TunnelIngress[];
  readonly previewWebhookRecord: TunnelRecordSpec;
  readonly filesRecord?: TunnelRecordSpec;
  readonly pepysRecord?: TunnelRecordSpec;
  readonly atc?: SidecarTunnelSpec;
  readonly boxxyDoor?: SidecarTunnelSpec;
}

// each route is set only with its workload
interface TunnelRouteInputs {
  readonly gateway?: GatewayIngress | undefined;
  readonly boxxyDoor?: GatewayIngress | undefined;
  readonly files?: TunnelRoute | undefined;
  readonly pepys?: TunnelRoute | undefined;
}

export function buildTunnelRouteSpecs(
  sharedTunnelID: Output<string>,
  routes: TunnelRouteInputs,
): TunnelRouteSpecs {
  const gateway = routes.gateway;
  const boxxyDoor = routes.boxxyDoor;
  const files = routes.files;
  const pepys = routes.pepys;
  const previewWebhookRoute = buildPreviewWebhookRoute();

  return {
    sharedIngresses: buildTunnelIngresses([
      previewWebhookRoute,
      ...(files === undefined ? [] : [files]),
      ...(pepys === undefined ? [] : [pepys]),
    ]),
    previewWebhookRecord: { hostname: previewWebhookRoute.hostname, tunnelID: sharedTunnelID },
    ...(files === undefined
      ? {}
      : { filesRecord: { hostname: files.hostname, tunnelID: sharedTunnelID } }),
    ...(pepys === undefined
      ? {}
      : { pepysRecord: { hostname: pepys.hostname, tunnelID: sharedTunnelID } }),
    ...(gateway === undefined
      ? {}
      : {
          atc: {
            ingresses: buildATCTunnelIngresses(gateway.hostname, gateway.access),
            record: { hostname: gateway.hostname, tunnelID: gateway.tunnelID },
          },
        }),
    ...(boxxyDoor === undefined
      ? {}
      : {
          boxxyDoor: {
            ingresses: buildBoxxyDoorIngresses(boxxyDoor.hostname, boxxyDoor.access),
            record: { hostname: boxxyDoor.hostname, tunnelID: boxxyDoor.tunnelID },
          },
        }),
  };
}

import type { Output } from '@pulumi/pulumi';
import { buildATCTunnelIngresses } from './build-atc-tunnel-ingresses.ts';
import { buildPepysAPIRoutes } from './build-pepys-api-routes.ts';
import { buildPreviewWebhookRoute } from './build-preview-webhook-route.ts';
import { buildTunnelIngresses } from './build-tunnel-ingresses.ts';
import type { OriginAccess, TunnelIngress, TunnelRoute } from './build-tunnel-ingresses.ts';

export interface GatewayIngress {
  readonly hostname: string;
  readonly access: OriginAccess;
  readonly tunnelID: Output<string>;
}

// a route whose browser paths pass cloudflared's Access check
export interface SignInIngress {
  readonly route: TunnelRoute;
  readonly access: OriginAccess;
}

export interface TunnelRecordSpec {
  readonly hostname: string;
  readonly tunnelID: Output<string>;
}

export interface TunnelRouteSpecs {
  readonly sharedIngresses: TunnelIngress[];
  readonly previewWebhookRecord: TunnelRecordSpec;
  readonly filesRecord?: TunnelRecordSpec;
  readonly pepysRecord?: TunnelRecordSpec;
  readonly pepysAPIRecord?: TunnelRecordSpec;
  readonly atc?: { readonly ingresses: TunnelIngress[]; readonly record: TunnelRecordSpec };
}

// each route is unset while its service does not run
interface ServiceRoutes {
  readonly gateway: GatewayIngress | undefined;
  readonly files: TunnelRoute | undefined;
  readonly pepys: TunnelRoute | undefined;
  readonly pepysAPI: SignInIngress | undefined;
}

export function buildTunnelRouteSpecs(
  sharedTunnelID: Output<string>,
  routes: ServiceRoutes,
): TunnelRouteSpecs {
  const gateway = routes.gateway;
  const files = routes.files;
  const pepys = routes.pepys;
  const pepysAPI = routes.pepysAPI;
  const previewWebhookRoute = buildPreviewWebhookRoute();

  return {
    sharedIngresses: buildTunnelIngresses([
      previewWebhookRoute,
      ...(files === undefined ? [] : [files]),
      ...(pepys === undefined ? [] : [pepys]),
      ...(pepysAPI === undefined ? [] : buildPepysAPIRoutes(pepysAPI.route, pepysAPI.access)),
    ]),
    previewWebhookRecord: { hostname: previewWebhookRoute.hostname, tunnelID: sharedTunnelID },
    ...(files === undefined
      ? {}
      : { filesRecord: { hostname: files.hostname, tunnelID: sharedTunnelID } }),
    ...(pepys === undefined
      ? {}
      : { pepysRecord: { hostname: pepys.hostname, tunnelID: sharedTunnelID } }),
    ...(pepysAPI === undefined
      ? {}
      : { pepysAPIRecord: { hostname: pepysAPI.route.hostname, tunnelID: sharedTunnelID } }),
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

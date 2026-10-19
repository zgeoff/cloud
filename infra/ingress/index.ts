import {
  ZeroTrustTunnelCloudflared,
  getZeroTrustTunnelCloudflaredTokenOutput,
} from '@pulumi/cloudflare';
import type { Provider } from '@pulumi/kubernetes';
import type { Output } from '@pulumi/pulumi';
import { secret } from '@pulumi/pulumi';
import type { TunnelRoute } from './build-tunnel-ingresses.ts';
import type { ATCTunnel } from './create-atc-tunnel.ts';
import { createCloudflared } from './create-cloudflared.ts';
import { createGatewayAccess } from './create-gateway-access.ts';
import { createTunnelRoutes } from './create-tunnel-routes.ts';
import type { GatewayIngress } from './create-tunnel-routes.ts';

// the names observability's monitor and alert rule select cloudflared by
export { cloudflaredNames } from './cloudflared-names.ts';

// the atc tunnel, made before the cluster so the gateway pod's sidecar gets its token
export { createATCTunnel } from './create-atc-tunnel.ts';

interface IngressInputs {
  readonly accountID: string;

  // geoff.cloud's zone, from the edge, for each route's CNAME
  readonly zoneID: Output<string>;

  // the k3s cluster cloudflared runs in; unset while the stack manages no cluster
  readonly cluster: Provider | undefined;

  // the atc gateway's route, set only with the gateway
  readonly atcRoute: TunnelRoute | undefined;

  // the one address the Access policy in front of the gateway's sign-in pages lets in, set with
  // the gateway
  readonly atcOwnerEmail: Output<string> | undefined;

  // the atc tunnel, set with the gateway
  readonly atcTunnel: ATCTunnel | undefined;
}

interface IngressOutputs {
  readonly tunnelToken: Output<string>;
  readonly tunnelConfigVersion: Output<number>;
  readonly atcTunnelConfigVersion?: Output<number>;
  readonly atcURL?: Output<string>;
  readonly previewWebhookURL: Output<string>;
}

// Public ingress (#7). The shared tunnel serves every public hostname under geoff.cloud but the
// gateway's, which the atc tunnel serves; cloudflared runs in k3s with the token below. Each
// workload brings its own auth, and Access fronts the gateway's sign-in pages on top of it.
export function createIngress(inputs: IngressInputs): IngressOutputs {
  const tunnel = new ZeroTrustTunnelCloudflared('edge', {
    accountId: inputs.accountID,
    name: 'geoff-cloud',
    configSrc: 'cloudflare',
  });

  // cloudflared's credential; it becomes a k3s Secret once the cluster exists (#6)
  const tunnelToken = secret(
    getZeroTrustTunnelCloudflaredTokenOutput({ accountId: inputs.accountID, tunnelId: tunnel.id })
      .token,
  );

  if (inputs.cluster !== undefined) {
    createCloudflared(inputs.cluster, tunnelToken);
  }

  // the routes: atc.geoff.cloud, a workload in k3s, on the atc tunnel, and the preview service's
  // webhook listener on the host, on this one
  const routes = createTunnelRoutes({
    accountID: inputs.accountID,
    zoneID: inputs.zoneID,
    tunnelID: tunnel.id,
    gateway: createGatewayIngress(inputs),
  });

  return {
    tunnelToken,
    tunnelConfigVersion: routes.configVersion,
    ...(routes.atcConfigVersion === undefined
      ? {}
      : { atcTunnelConfigVersion: routes.atcConfigVersion }),
    ...(routes.atcURL === undefined ? {} : { atcURL: routes.atcURL }),
    previewWebhookURL: routes.previewWebhookURL,
  };
}

// the gateway's route with its Access application and its tunnel, or nothing without the gateway;
// the program sets the route, the owner address and the tunnel together, so one without the
// others is a wiring fault
function createGatewayIngress(inputs: IngressInputs): GatewayIngress | undefined {
  const atcRoute = inputs.atcRoute;
  const atcOwnerEmail = inputs.atcOwnerEmail;
  const atcTunnel = inputs.atcTunnel;

  if (atcRoute === undefined) {
    return undefined;
  }

  if (atcOwnerEmail === undefined) {
    throw new Error("the atc gateway's route has no owner address for its Access policy");
  }

  if (atcTunnel === undefined) {
    throw new Error("the atc gateway's route has no atc tunnel");
  }

  return {
    route: atcRoute,
    tunnelID: atcTunnel.tunnelID,
    access: createGatewayAccess({
      accountID: inputs.accountID,
      hostname: atcRoute.hostname,
      ownerEmail: atcOwnerEmail,
    }),
  };
}

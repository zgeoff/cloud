import {
  ZeroTrustTunnelCloudflared,
  getZeroTrustTunnelCloudflaredTokenOutput,
} from '@pulumi/cloudflare';
import type { Provider } from '@pulumi/kubernetes';
import type { Output } from '@pulumi/pulumi';
import { secret } from '@pulumi/pulumi';
import type { TunnelRoute } from './build-tunnel-ingresses.ts';
import type { GatewayIngress } from './build-tunnel-route-specs.ts';
import type { ATCTunnel } from './create-atc-tunnel.ts';
import { createCloudflared } from './create-cloudflared.ts';
import { createGatewayAccess } from './create-gateway-access.ts';
import { createTunnelRoutes } from './create-tunnel-routes.ts';

export { cloudflaredNames } from './cloudflared-names.ts';

// made before the cluster, so the gateway pod's sidecar gets the tunnel's token
export { createATCTunnel } from './create-atc-tunnel.ts';

interface IngressInputs {
  readonly accountID: string;
  readonly zoneID: Output<string>;
  readonly cluster: Provider | undefined;

  // set only with the gateway
  readonly atcRoute: TunnelRoute | undefined;

  // the one address the Access policy in front of the gateway's sign-in pages lets in, set with
  // the gateway
  readonly atcOwnerEmail: Output<string> | undefined;

  // set only with the gateway
  readonly atcTunnel: ATCTunnel | undefined;

  // set only with the files service
  readonly filesRoute: TunnelRoute | undefined;
}

interface IngressOutputs {
  readonly tunnelToken: Output<string>;
  readonly tunnelConfigVersion: Output<number>;
  readonly atcTunnelConfigVersion?: Output<number>;
  readonly atcURL?: Output<string>;
  readonly filesURL?: Output<string>;
  readonly previewWebhookURL: Output<string>;
}

export function createIngress(inputs: IngressInputs): IngressOutputs {
  const tunnel = new ZeroTrustTunnelCloudflared('edge', {
    accountId: inputs.accountID,
    name: 'geoff-cloud',
    configSrc: 'cloudflare',
  });

  // cloudflared's credential; it becomes a k3s Secret once the cluster exists
  const tunnelToken = secret(
    getZeroTrustTunnelCloudflaredTokenOutput({ accountId: inputs.accountID, tunnelId: tunnel.id })
      .token,
  );

  if (inputs.cluster !== undefined) {
    createCloudflared(inputs.cluster, tunnelToken);
  }

  const routes = createTunnelRoutes({
    accountID: inputs.accountID,
    zoneID: inputs.zoneID,
    tunnelID: tunnel.id,
    gateway: createGatewayIngress(inputs),
    files: inputs.filesRoute,
  });

  return {
    tunnelToken,
    tunnelConfigVersion: routes.configVersion,
    ...(routes.atcConfigVersion === undefined
      ? {}
      : { atcTunnelConfigVersion: routes.atcConfigVersion }),
    ...(routes.atcURL === undefined ? {} : { atcURL: routes.atcURL }),
    ...(routes.filesURL === undefined ? {} : { filesURL: routes.filesURL }),
    previewWebhookURL: routes.previewWebhookURL,
  };
}

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
    hostname: atcRoute.hostname,
    tunnelID: atcTunnel.tunnelID,
    access: createGatewayAccess({
      accountID: inputs.accountID,
      hostname: atcRoute.hostname,
      ownerEmail: atcOwnerEmail,
    }),
  };
}

import {
  ZeroTrustAccessIdentityProvider,
  ZeroTrustTunnelCloudflared,
  getZeroTrustTunnelCloudflaredTokenOutput,
} from '@pulumi/cloudflare';
import type { Provider } from '@pulumi/kubernetes';
import type { Output } from '@pulumi/pulumi';
import { secret } from '@pulumi/pulumi';
import { atcGatewayPaths } from './atc-gateway-paths.ts';
import { boxxyDoorPaths } from './boxxy-door-paths.ts';
import type { TunnelRoute } from './build-tunnel-ingresses.ts';
import type { GatewayIngress } from './build-tunnel-route-specs.ts';
import { createCloudflared } from './create-cloudflared.ts';
import { createOwnerAccess } from './create-owner-access.ts';
import type { SidecarTunnel } from './create-sidecar-tunnel.ts';
import { createTunnelRoutes } from './create-tunnel-routes.ts';

export { cloudflaredNames } from './cloudflared-names.ts';

// made before the cluster, so the sidecar in the gateway's pod, or in the boxxy server's, gets the
// tunnel's token
export { createSidecarTunnel } from './create-sidecar-tunnel.ts';

interface IngressInputs {
  readonly accountID: string;
  readonly zoneID: Output<string>;
  readonly cluster: Provider | undefined;

  // set only with the gateway
  readonly atcRoute: TunnelRoute | undefined;

  // the one address the Access policies in front of the gateway's and the boxxy door's sign-in
  // pages let in, set with the gateway
  readonly atcOwnerEmail: Output<string> | undefined;

  // set only with the gateway
  readonly atcTunnel: SidecarTunnel | undefined;

  // set only with the boxxy server's public door, with the door's own tunnel
  readonly boxxyDoorHostname?: string | undefined;
  readonly boxxyTunnel?: SidecarTunnel | undefined;

  // set only with the files service
  readonly filesRoute: TunnelRoute | undefined;

  // set only with pepys, while a route of its deployment is public
  readonly pepysRoute: TunnelRoute | undefined;
}

interface IngressOutputs {
  readonly tunnelToken: Output<string>;
  readonly tunnelConfigVersion: Output<number>;
  readonly atcTunnelConfigVersion?: Output<number>;
  readonly atcURL?: Output<string>;
  readonly boxxyDoorConfigVersion?: Output<number>;
  readonly boxxyDoorURL?: Output<string>;
  readonly filesURL?: Output<string>;
  readonly pepysWebhookURL?: Output<string>;
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

  const ownerLogin = createOwnerLogin(inputs);

  const routes = createTunnelRoutes({
    accountID: inputs.accountID,
    zoneID: inputs.zoneID,
    tunnelID: tunnel.id,
    gateway: createGatewayIngress(inputs, ownerLogin),
    boxxyDoor: createBoxxyDoorIngress(inputs, ownerLogin),
    files: inputs.filesRoute,
    pepys: inputs.pepysRoute,
  });

  return {
    tunnelToken,
    tunnelConfigVersion: routes.configVersion,
    ...(routes.atcConfigVersion === undefined
      ? {}
      : { atcTunnelConfigVersion: routes.atcConfigVersion }),
    ...(routes.atcURL === undefined ? {} : { atcURL: routes.atcURL }),
    ...(routes.boxxyDoorConfigVersion === undefined
      ? {}
      : { boxxyDoorConfigVersion: routes.boxxyDoorConfigVersion }),
    ...(routes.boxxyDoorURL === undefined ? {} : { boxxyDoorURL: routes.boxxyDoorURL }),
    ...(routes.filesURL === undefined ? {} : { filesURL: routes.filesURL }),
    ...(routes.pepysURL === undefined ? {} : { pepysWebhookURL: routes.pepysURL }),
    previewWebhookURL: routes.previewWebhookURL,
  };
}

interface OwnerLogin {
  readonly ownerEmail: Output<string>;
  readonly identityProviderID: Output<string>;
}

// The account's one-time PIN login, which needs no outside identity provider, for the owner's
// address. An account holds one such login, so every owner-only application shares it.
function createOwnerLogin(inputs: IngressInputs): OwnerLogin | undefined {
  if (inputs.atcOwnerEmail === undefined) {
    return undefined;
  }

  const identityProvider = new ZeroTrustAccessIdentityProvider('one-time-pin', {
    accountId: inputs.accountID,
    name: 'One-time PIN',
    type: 'onetimepin',
    config: {},
  });

  return { ownerEmail: inputs.atcOwnerEmail, identityProviderID: identityProvider.id };
}

// the program sets the route, the owner address and the tunnel together, so one without the
// others is a wiring fault
function createGatewayIngress(
  inputs: IngressInputs,
  ownerLogin: OwnerLogin | undefined,
): GatewayIngress | undefined {
  const atcRoute = inputs.atcRoute;
  const atcTunnel = inputs.atcTunnel;

  if (atcRoute === undefined) {
    return undefined;
  }

  if (ownerLogin === undefined) {
    throw new Error("the atc gateway's route has no owner address for its Access policy");
  }

  if (atcTunnel === undefined) {
    throw new Error("the atc gateway's route has no atc tunnel");
  }

  return {
    hostname: atcRoute.hostname,
    tunnelID: atcTunnel.tunnelID,
    access: createOwnerAccess({
      accountID: inputs.accountID,
      resourceName: 'atc-gateway',
      name: 'atc gateway',
      hostname: atcRoute.hostname,
      browserPaths: atcGatewayPaths.browser,
      ...ownerLogin,
    }),
  };
}

// the boxxy server deploys only beside the gateway, so its door shares the gateway's owner address
function createBoxxyDoorIngress(
  inputs: IngressInputs,
  ownerLogin: OwnerLogin | undefined,
): GatewayIngress | undefined {
  const hostname = inputs.boxxyDoorHostname;
  const boxxyTunnel = inputs.boxxyTunnel;

  if (hostname === undefined) {
    return undefined;
  }

  if (ownerLogin === undefined) {
    throw new Error("the boxxy door's route has no owner address for its Access policy");
  }

  if (boxxyTunnel === undefined) {
    throw new Error("the boxxy door's route has no boxxy tunnel");
  }

  return {
    hostname,
    tunnelID: boxxyTunnel.tunnelID,
    access: createOwnerAccess({
      accountID: inputs.accountID,
      resourceName: 'boxxy-door',
      name: 'boxxy door',
      hostname,
      browserPaths: boxxyDoorPaths.browser,
      ...ownerLogin,
    }),
  };
}

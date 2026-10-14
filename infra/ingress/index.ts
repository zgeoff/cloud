import {
  ZeroTrustTunnelCloudflared,
  getZeroTrustTunnelCloudflaredTokenOutput,
} from '@pulumi/cloudflare';
import type { Provider } from '@pulumi/kubernetes';
import type { Output } from '@pulumi/pulumi';
import { secret } from '@pulumi/pulumi';
import type { TunnelRoute } from './build-tunnel-ingresses.ts';
import { createCloudflared } from './create-cloudflared.ts';
import { createTunnelRoutes } from './create-tunnel-routes.ts';

// the names observability's monitor and alert rule select cloudflared by
export { cloudflaredNames } from './cloudflared-names.ts';

interface IngressInputs {
  readonly accountID: string;

  // geoff.cloud's zone, from the edge, for each route's CNAME
  readonly zoneID: Output<string>;

  // the k3s cluster cloudflared runs in; unset while the stack manages no cluster
  readonly cluster: Provider | undefined;

  // the atc gateway's route, set only with the gateway
  readonly atcRoute: TunnelRoute | undefined;
}

interface IngressOutputs {
  readonly tunnelToken: Output<string>;
  readonly tunnelConfigVersion: Output<number>;
  readonly atcURL?: Output<string>;
}

// Public ingress (#7). One tunnel for every public hostname under geoff.cloud;
// cloudflared runs in k3s with the token below. Each workload brings its own auth.
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

  // the tunnel's one route: atc.geoff.cloud, a workload in k3s
  const routes = createTunnelRoutes({
    accountID: inputs.accountID,
    zoneID: inputs.zoneID,
    tunnelID: tunnel.id,
    atcRoute: inputs.atcRoute,
  });

  return {
    tunnelToken,
    tunnelConfigVersion: routes.configVersion,
    ...(routes.atcURL === undefined ? {} : { atcURL: routes.atcURL }),
  };
}

import type { Provider } from '@pulumi/kubernetes';
import type { Output } from '@pulumi/pulumi';
import type { ATCGatewayInputs, NixieInputs } from '../inputs/index.ts';
import { createATCGateway } from './atc-gateway.ts';
import type { ATCGatewayRoute } from './build-atc-gateway-route-outputs.ts';
import { buildATCGatewayRouteOutputs } from './build-atc-gateway-route-outputs.ts';
import { createNixie } from './nixie.ts';
import type { OnePasswordConnectInputs } from './onepassword-connect.ts';
import { createOnePasswordConnect } from './onepassword-connect.ts';

interface ClusterInputs {
  // set only after the owner approves the deploy
  readonly atcGateway?: ATCGatewayInputs;

  // 1Password Connect for imps (GEO-120)
  readonly onePasswordConnect: OnePasswordConnectInputs;

  // set only after the owner approves the deploy (GEO-343)
  readonly nixie?: NixieInputs;

  // geoff.cloud's zone, for nixie's DNS record
  readonly zoneID: Output<string>;
}

// the gateway's and Connect's outputs, and nixie's
interface ClusterOutputs {
  readonly atcGatewayServiceURL?: Output<string>;
  readonly atcGatewayRoute?: ATCGatewayRoute;
  readonly onePasswordConnectServiceURL: Output<string>;
  readonly nixieURL?: Output<string>;
}

// Workloads on the geoffcloud k3s cluster (#6, #7). index.ts builds the cluster's Provider, which
// reaches the k3s API over the tailnet with the kubeconfig from op://cloud/k3s-kubeconfig.
export function createCluster(cluster: Provider, inputs: ClusterInputs): ClusterOutputs {
  const gateway =
    inputs.atcGateway === undefined ? undefined : createATCGateway(cluster, inputs.atcGateway);

  const connect = createOnePasswordConnect(cluster, inputs.onePasswordConnect);

  const nixie =
    inputs.nixie === undefined ? undefined : createNixie(cluster, inputs.nixie, inputs.zoneID);

  return {
    onePasswordConnectServiceURL: connect.serviceURL,
    ...(nixie === undefined ? {} : { nixieURL: nixie.url }),
    ...(gateway === undefined ? {} : buildATCGatewayRouteOutputs(gateway)),
  };
}

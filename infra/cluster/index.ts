import type { Provider } from '@pulumi/kubernetes';
import type { Output } from '@pulumi/pulumi';
import type { ATCGatewayInputs, FilesInputs, NixieInputs } from '../inputs/index.ts';
import { createK3sNamespacePatches } from '../shared/create-k3s-namespace-patches.ts';
import { createATCGateway } from './atc-gateway.ts';
import type { ATCGatewayRoute } from './build-atc-gateway-route-outputs.ts';
import { buildATCGatewayRouteOutputs } from './build-atc-gateway-route-outputs.ts';
import type { FilesRoute } from './create-files.ts';
import { createFiles } from './create-files.ts';
import { nixieReadinessURL } from './nixie-readiness-url.ts';
import { createNixie } from './nixie.ts';
import type { OnePasswordConnectInputs } from './onepassword-connect.ts';
import { createOnePasswordConnect } from './onepassword-connect.ts';

// the cluster's Kubernetes provider, with the port-forward guard registered first
export { createClusterProvider } from './create-cluster-provider.ts';

interface ClusterInputs {
  // set only after the owner approves the deploy, with the token of the atc tunnel that the
  // gateway pod's cloudflared sidecar runs
  readonly atcGateway?: { readonly inputs: ATCGatewayInputs; readonly tunnelToken: Output<string> };

  // 1Password Connect for imps (GEO-120)
  readonly onePasswordConnect: OnePasswordConnectInputs;

  // set only after the owner approves the deploy (GEO-343)
  readonly nixie?: NixieInputs;

  // set only after the owner approves the deploy (GEO-1364)
  readonly files?: FilesInputs;

  // geoff.cloud's zone, for nixie's DNS record
  readonly zoneID: Output<string>;
}

// the gateway's and Connect's outputs, and nixie's
interface ClusterOutputs {
  readonly atcGatewayServiceURL?: Output<string>;
  readonly atcGatewayRoute?: ATCGatewayRoute;
  readonly onePasswordConnectServiceURL: Output<string>;
  readonly nixieURL?: Output<string>;

  // the in-cluster URL of nixie's readiness report, for the probe of its advisory parts
  readonly nixieReadinessURL?: string;

  // the files service's public hostname and in-cluster URL, for its tunnel route
  readonly filesRoute?: FilesRoute;
}

// Workloads on the geoffcloud k3s cluster (#6, #7). index.ts builds the cluster's Provider, which
// reaches the k3s API over the tailnet with the kubeconfig from op://cloud/k3s-kubeconfig.
export function createCluster(cluster: Provider, inputs: ClusterInputs): ClusterOutputs {
  createK3sNamespacePatches(cluster);

  const gateway =
    inputs.atcGateway === undefined
      ? undefined
      : createATCGateway(cluster, inputs.atcGateway.inputs, inputs.atcGateway.tunnelToken);

  const connect = createOnePasswordConnect(cluster, inputs.onePasswordConnect);

  const nixie =
    inputs.nixie === undefined ? undefined : createNixie(cluster, inputs.nixie, inputs.zoneID);

  const files = inputs.files === undefined ? undefined : createFiles(cluster, inputs.files);

  return {
    onePasswordConnectServiceURL: connect.serviceURL,
    ...(files === undefined ? {} : { filesRoute: files.route }),
    ...(nixie === undefined ? {} : { nixieURL: nixie.url, nixieReadinessURL }),
    ...(gateway === undefined ? {} : buildATCGatewayRouteOutputs(gateway)),
  };
}

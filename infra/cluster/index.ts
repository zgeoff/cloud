import type { Provider } from '@pulumi/kubernetes';
import type { Output } from '@pulumi/pulumi';
import type {
  ATCGatewayInputs,
  BoxxyInputs,
  FilesInputs,
  NixieInputs,
  PepysInputs,
} from '../inputs/index.ts';
import { createK3sNamespaceEgressDenies } from '../shared/create-k3s-namespace-egress-denies.ts';
import { createK3sNamespacePatches } from '../shared/create-k3s-namespace-patches.ts';
import { createATCGateway } from './atc-gateway.ts';
import type { ATCGatewayRoute } from './build-atc-gateway-route-outputs.ts';
import { buildATCGatewayRouteOutputs } from './build-atc-gateway-route-outputs.ts';
import { createBoxxy } from './create-boxxy.ts';
import type { FilesRoute } from './create-files.ts';
import { createFiles } from './create-files.ts';
import type { PepysRoute } from './create-pepys.ts';
import { createPepys } from './create-pepys.ts';
import { nixieReadinessURL } from './nixie-readiness-url.ts';
import { createNixie } from './nixie.ts';
import type { OnePasswordConnectInputs } from './onepassword-connect.ts';
import { createOnePasswordConnect } from './onepassword-connect.ts';

export { createClusterProvider } from './create-cluster-provider.ts';

interface ClusterInputs {
  // set only after the owner approves the deploy, with the token of the atc tunnel that the
  // gateway pod's cloudflared sidecar runs
  readonly atcGateway?: { readonly inputs: ATCGatewayInputs; readonly tunnelToken: Output<string> };

  readonly onePasswordConnect: OnePasswordConnectInputs;

  // set only after the owner approves the deploy
  readonly nixie?: NixieInputs;

  // set only after the owner approves the deploy
  readonly files?: FilesInputs;

  // set only after the owner approves the deploy
  readonly pepys?: PepysInputs;
  readonly boxxy?: BoxxyInputs;

  // geoff.cloud's zone, for nixie's DNS record
  readonly zoneID: Output<string>;

  // k3s's admin kubeconfig, which starts the Job that adds nixie's sandbox images before it rolls
  readonly kubeconfig: Output<string>;
}

interface ClusterOutputs {
  readonly atcGatewayServiceURL?: Output<string>;
  readonly atcGatewayRoute?: ATCGatewayRoute;
  readonly onePasswordConnectServiceURL: Output<string>;
  readonly nixieURL?: Output<string>;

  // the in-cluster URL of nixie's readiness report, for the probe of its advisory parts
  readonly nixieReadinessURL?: string;
  readonly filesRoute?: FilesRoute;
  readonly pepysRoute?: PepysRoute;

  // the boxxy server's owner listener in the cluster
  readonly boxxyServiceURL?: Output<string>;
}

export function createCluster(cluster: Provider, inputs: ClusterInputs): ClusterOutputs {
  createK3sNamespacePatches(cluster);
  createK3sNamespaceEgressDenies(cluster);

  const gateway =
    inputs.atcGateway === undefined
      ? undefined
      : createATCGateway(cluster, inputs.atcGateway.inputs, inputs.atcGateway.tunnelToken);

  const connect = createOnePasswordConnect(cluster, inputs.onePasswordConnect);

  const nixie =
    inputs.nixie === undefined
      ? undefined
      : createNixie(cluster, inputs.nixie, {
          zoneID: inputs.zoneID,
          kubeconfig: inputs.kubeconfig,
        });

  const files = inputs.files === undefined ? undefined : createFiles(cluster, inputs.files);
  const pepys = inputs.pepys === undefined ? undefined : createPepys(cluster, inputs.pepys);

  const boxxy =
    inputs.boxxy === undefined
      ? undefined
      : createBoxxy(cluster, requirePepys(inputs.boxxy, pepys), requireGateway(gateway));

  return {
    onePasswordConnectServiceURL: connect.serviceURL,
    ...(files === undefined ? {} : { filesRoute: files.route }),
    ...(pepys?.route === undefined ? {} : { pepysRoute: pepys.route }),
    ...(boxxy === undefined ? {} : { boxxyServiceURL: boxxy.ownerServiceURL }),
    ...(nixie === undefined ? {} : { nixieURL: nixie.url, nixieReadinessURL }),
    ...(gateway === undefined ? {} : buildATCGatewayRouteOutputs(gateway)),
  };
}

// the server's facts and reports go to the pepys in this cluster, so its section needs pepys here
function requirePepys(boxxy: BoxxyInputs, pepys: unknown): BoxxyInputs {
  if (boxxy.config.pepys !== undefined && pepys === undefined) {
    throw new Error(
      'stack config "boxxy.pepys" needs stack config "pepys": the boxxy server sends its facts to the pepys in the cluster',
    );
  }

  return boxxy;
}

// the boxxy server calls atc through the gateway's Service, so it deploys only beside the gateway
function requireGateway<Gateway>(gateway: Gateway | undefined): Gateway {
  if (gateway === undefined) {
    throw new Error(
      'stack config "boxxy" needs stack config "atcGateway": the boxxy server calls atc through the gateway',
    );
  }

  return gateway;
}

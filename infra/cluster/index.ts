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
import { pepysWorkloads } from '../shared/pepys-workloads.ts';
import type { ATCGatewayRoute } from './build-atc-gateway-route-outputs.ts';
import { buildATCGatewayRouteOutputs } from './build-atc-gateway-route-outputs.ts';
import { buildNixieRoutesNamespaces } from './build-nixie-routes-namespaces.ts';
import { buildPepysForwarderIngress } from './build-pepys-forwarder-ingress.ts';
import { buildPepysTailnetIngressSpec } from './build-pepys-tailnet-ingress-spec.ts';
import { createATCGateway } from './create-atc-gateway.ts';
import { createBoxxy } from './create-boxxy.ts';
import type { FilesRoute } from './create-files.ts';
import { createFiles } from './create-files.ts';
import { createNixie } from './create-nixie.ts';
import type { OnePasswordConnectInputs } from './create-one-password-connect.ts';
import { createOnePasswordConnect } from './create-one-password-connect.ts';
import { createPepysTailnetRoute } from './create-pepys-tailnet-route.ts';
import type { PepysAPIRoute, PepysRoute } from './create-pepys.ts';
import { createPepys } from './create-pepys.ts';
import { nixieReadinessURL } from './nixie-readiness-url.ts';

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

  // set with the boxxy server's public door: the token of the door's tunnel, whose connector runs
  // in the server's pod
  readonly boxxyDoorTunnelToken?: Output<string>;

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
  readonly pepysAPIRoute?: PepysAPIRoute;

  // the API's every path on the host's tailnet address, through nixie's Traefik
  readonly pepysTailnetURL?: Output<string>;

  // ingest's /forwarded/v1/logs alone on the host's tailnet address, through nixie's Traefik
  readonly pepysForwarderURL?: Output<string>;

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
  const pepysTailnetHostnames = requireNixieRoutes(inputs);
  const pepysTailnetHostname = pepysTailnetHostnames.api;
  const pepysForwarderHostname = pepysTailnetHostnames.forwarder;

  const nixie =
    inputs.nixie === undefined
      ? undefined
      : createNixie(cluster, inputs.nixie, {
          zoneID: inputs.zoneID,
          kubeconfig: inputs.kubeconfig,
          routesNamespaces: buildNixieRoutesNamespaces(
            pepysTailnetHostname !== undefined || pepysForwarderHostname !== undefined,
          ),
        });

  const files = inputs.files === undefined ? undefined : createFiles(cluster, inputs.files);
  const pepys = inputs.pepys === undefined ? undefined : createPepys(cluster, inputs.pepys);

  const pepysTailnetURL =
    pepys === undefined || nixie === undefined || pepysTailnetHostname === undefined
      ? undefined
      : createPepysTailnetRoute(cluster, {
          name: 'pepys-api-tailnet',
          hostname: pepysTailnetHostname,
          namespace: pepys.namespace,
          routes: nixie.tailnetRoutes,
          buildIngress: (tlsSecret) => ({
            spec: buildPepysTailnetIngressSpec({
              hostname: pepysTailnetHostname,
              ingressClass: nixie.tailnetRoutes.ingressClass,
              tlsSecret,
              service: pepys.apiService,
              port: pepysWorkloads.host.apiPort,
            }),
          }),
        });

  const pepysForwarderURL =
    pepys === undefined || nixie === undefined || pepysForwarderHostname === undefined
      ? undefined
      : createPepysTailnetRoute(cluster, {
          name: 'pepys-forwarder-tailnet',
          hostname: pepysForwarderHostname,
          namespace: pepys.namespace,
          routes: nixie.tailnetRoutes,
          buildIngress: (tlsSecret) =>
            buildPepysForwarderIngress({
              hostname: pepysForwarderHostname,
              ingressClass: nixie.tailnetRoutes.ingressClass,
              tlsSecret,
              service: pepys.ingestService,
              port: pepysWorkloads.ingest.port,
            }),
        });

  const boxxy =
    inputs.boxxy === undefined
      ? undefined
      : createBoxxy(
          cluster,
          requirePepys(inputs.boxxy, pepys),
          requireGateway(gateway),
          inputs.boxxyDoorTunnelToken,
        );

  return {
    onePasswordConnectServiceURL: connect.serviceURL,
    ...(files === undefined ? {} : { filesRoute: files.route }),
    ...(pepys?.route === undefined ? {} : { pepysRoute: pepys.route }),
    ...(pepys?.apiRoute === undefined ? {} : { pepysAPIRoute: pepys.apiRoute }),
    ...(pepysTailnetURL === undefined ? {} : { pepysTailnetURL }),
    ...(pepysForwarderURL === undefined ? {} : { pepysForwarderURL }),
    ...(boxxy === undefined ? {} : { boxxyServiceURL: boxxy.ownerServiceURL }),
    ...(nixie === undefined ? {} : { nixieURL: nixie.url, nixieReadinessURL }),
    ...(gateway === undefined ? {} : buildATCGatewayRouteOutputs(gateway)),
  };
}

interface PepysTailnetHostnames {
  readonly api: string | undefined;
  readonly forwarder: string | undefined;
}

// pepys's tailnet routes go through nixie's Traefik, which alone holds the host's tailnet 443
function requireNixieRoutes(inputs: ClusterInputs): PepysTailnetHostnames {
  const hostnames = {
    api: inputs.pepys?.config.tailnetHostname,
    forwarder: inputs.pepys?.config.forwarder?.hostname,
  };

  const keys = [
    ['pepys.tailnetHostname', hostnames.api],
    ['pepys.forwarder', hostnames.forwarder],
  ] as const;

  for (const [key, hostname] of keys) {
    if (hostname !== undefined && inputs.nixie === undefined) {
      throw new Error(
        `stack config "${key}" needs stack config "nixie": the route goes through nixie's Traefik`,
      );
    }
  }

  return hostnames;
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

import { Provider } from '@pulumi/kubernetes';
import type { Output } from '@pulumi/pulumi';
import { createATCGateway } from './atc-gateway.ts';
import { buildATCDaemonEndpoints } from './build-atc-daemon-endpoints.ts';
import type { ATCGatewayRoute } from './build-atc-gateway-route-outputs.ts';
import { buildATCGatewayRouteOutputs } from './build-atc-gateway-route-outputs.ts';
import type { CloudflaredOutputs } from './create-cloudflared.ts';
import { createCloudflared } from './create-cloudflared.ts';
import type { ATCGatewayInputs } from './inputs/types.ts';
import type { NixieInputs } from './nixie.ts';
import { createNixie } from './nixie.ts';
import type { ObservabilityOutputs } from './observability.ts';
import { createObservability } from './observability.ts';
import type { OnePasswordConnectInputs } from './onepassword-connect.ts';
import { createOnePasswordConnect } from './onepassword-connect.ts';

interface ClusterInputs {
  readonly kubeconfig: string;
  readonly tunnelToken: Output<string>;

  // In-cluster alerts reach Discord only after `pulumi config set discordAlerts true` (#29);
  // until then no Secret holds the webhook and Alertmanager sends nothing. The inputs group
  // reads ALERT_WEBHOOK_URL once for this and the external health check.
  readonly alertWebhookURL: string | undefined;

  // set only after the owner approves the deploy
  readonly atcGateway?: ATCGatewayInputs;

  // 1Password Connect for imps (GEO-120)
  readonly onePasswordConnect: OnePasswordConnectInputs;

  // set only after the owner approves the deploy (GEO-343)
  readonly nixie?: NixieInputs;

  // geoff.cloud's zone, for nixie's DNS record
  readonly zoneID: Output<string>;
}

// cloudflared's and observability's outputs, and the gateway's and Connect's
interface ClusterOutputs extends CloudflaredOutputs, ObservabilityOutputs {
  readonly atcGatewayServiceURL?: Output<string>;
  readonly atcGatewayRoute?: ATCGatewayRoute;
  readonly onePasswordConnectServiceURL: Output<string>;
  readonly nixieURL?: Output<string>;
}

// Workloads on the geoffcloud k3s cluster (#6, #7, #8). Pulumi reaches the k3s API
// over the tailnet with the kubeconfig from op://cloud/k3s-kubeconfig.
export function createClusterWorkloads(inputs: ClusterInputs): ClusterOutputs {
  const cluster = new Provider('geoffcloud', { kubeconfig: inputs.kubeconfig });

  const ingress = createCloudflared(cluster, inputs.tunnelToken);
  const atcDaemons = buildATCDaemonEndpoints(inputs.atcGateway?.config);
  const observability = createObservability(cluster, inputs.alertWebhookURL, atcDaemons);

  const gateway =
    inputs.atcGateway === undefined ? undefined : createATCGateway(cluster, inputs.atcGateway);

  const connect = createOnePasswordConnect(cluster, inputs.onePasswordConnect);

  const nixie =
    inputs.nixie === undefined ? undefined : createNixie(cluster, inputs.nixie, inputs.zoneID);

  return {
    ...ingress,
    ...observability,
    onePasswordConnectServiceURL: connect.serviceURL,
    ...(nixie === undefined ? {} : { nixieURL: nixie.url }),
    ...(gateway === undefined ? {} : buildATCGatewayRouteOutputs(gateway)),
  };
}

import { Provider } from '@pulumi/kubernetes';
import type { Output } from '@pulumi/pulumi';
import { Config } from '@pulumi/pulumi';
import type { ATCGatewayInputs } from './atc-gateway.ts';
import { createATCGateway } from './atc-gateway.ts';
import { buildATCDaemonEndpoints } from './build-atc-daemon-endpoints.ts';
import type { ATCGatewayRoute } from './build-atc-gateway-route-outputs.ts';
import { buildATCGatewayRouteOutputs } from './build-atc-gateway-route-outputs.ts';
import type { CloudflaredOutputs } from './create-cloudflared.ts';
import { createCloudflared } from './create-cloudflared.ts';
import type { ObservabilityOutputs } from './observability.ts';
import { createObservability } from './observability.ts';
import type { OnePasswordConnectInputs } from './onepassword-connect.ts';
import { createOnePasswordConnect } from './onepassword-connect.ts';
import { requireAlertWebhook } from './require-alert-webhook.ts';

interface ClusterInputs {
  readonly kubeconfig: string;
  readonly tunnelToken: Output<string>;

  // set only after the operator checklist's approval step
  readonly atcGateway?: ATCGatewayInputs;

  // 1Password Connect for imps (GEO-120)
  readonly onePasswordConnect: OnePasswordConnectInputs;
}

// cloudflared's and observability's outputs, and the gateway's and Connect's
interface ClusterOutputs extends CloudflaredOutputs, ObservabilityOutputs {
  readonly atcGatewayServiceURL?: Output<string>;
  readonly atcGatewayRoute?: ATCGatewayRoute;
  readonly onePasswordConnectServiceURL: Output<string>;
}

// Workloads on the geoffcloud k3s cluster (#6, #7, #8). Pulumi reaches the k3s API
// over the tailnet with the kubeconfig from op://cloud/k3s-kubeconfig.
export function createClusterWorkloads(inputs: ClusterInputs): ClusterOutputs {
  const cluster = new Provider('geoffcloud', { kubeconfig: inputs.kubeconfig });

  const ingress = createCloudflared(cluster, inputs.tunnelToken);

  // In-cluster alerts reach Discord only after `pulumi config set discordAlerts true`
  // (#29); until then no Secret holds the webhook and Alertmanager sends nothing. The
  // external health check (health-check.ts) reads the same webhook on its own.
  const alertWebhookURL = requireAlertWebhook(
    new Config().getBoolean('discordAlerts') ?? false,
    process.env['ALERT_WEBHOOK_URL'],
  );

  const atcDaemons = buildATCDaemonEndpoints(inputs.atcGateway);
  const observability = createObservability(cluster, alertWebhookURL, atcDaemons);

  const gateway =
    inputs.atcGateway === undefined ? undefined : createATCGateway(cluster, inputs.atcGateway);

  const connect = createOnePasswordConnect(cluster, inputs.onePasswordConnect);

  return {
    ...ingress,
    ...observability,
    onePasswordConnectServiceURL: connect.serviceURL,
    ...(gateway === undefined ? {} : buildATCGatewayRouteOutputs(gateway)),
  };
}

import { Provider } from '@pulumi/kubernetes';
import type { Deployment } from '@pulumi/kubernetes/apps/v1';
import type { Chart } from '@pulumi/kubernetes/helm/v4';
import type { Output } from '@pulumi/pulumi';
import { Config } from '@pulumi/pulumi';
import type { ATCGatewayInputs, ATCGatewayOutputs } from './atc-gateway.ts';
import { createATCGateway } from './atc-gateway.ts';
import type { ATCDaemonEndpoint } from './build-alert-rules.ts';
import { createCloudflared } from './create-cloudflared.ts';
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

// the tunnel ingress for the gateway's public hostname, and the URL the external health
// check probes there
interface ATCGatewayRoute {
  readonly hostname: string;
  readonly service: Output<string>;
  readonly healthURL: string;
}

interface ClusterOutputs {
  readonly ingressNamespace: Output<string>;
  readonly cloudflared: Deployment;
  readonly logShipper: Chart;
  readonly grafanaURL: string;
  readonly grafanaAdminPassword: Output<string>;
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
    ...(gateway === undefined ? {} : buildGatewayOutputs(gateway)),
  };
}

// the gateway's daemons, for the probe and its alert; none without the gateway
function buildATCDaemonEndpoints(
  gateway: ATCGatewayInputs | undefined,
): readonly ATCDaemonEndpoint[] | undefined {
  if (gateway === undefined) {
    return undefined;
  }

  return Object.entries(gateway.daemons).map(([name, daemon]) => ({
    name,
    address: daemon.address,
    alertSeverity: daemon.alertSeverity,
  }));
}

interface GatewayOutputs {
  readonly atcGatewayServiceURL: Output<string>;
  readonly atcGatewayRoute: ATCGatewayRoute;
}

function buildGatewayOutputs(gateway: ATCGatewayOutputs): GatewayOutputs {
  return {
    atcGatewayServiceURL: gateway.serviceURL,
    atcGatewayRoute: {
      hostname: gateway.publicHost,
      service: gateway.serviceURL,
      healthURL: `https://${gateway.publicHost}/.well-known/oauth-protected-resource/mcp`,
    },
  };
}

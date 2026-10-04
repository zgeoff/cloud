import { Provider } from '@pulumi/kubernetes';
import { Deployment } from '@pulumi/kubernetes/apps/v1';
import { Namespace, Secret } from '@pulumi/kubernetes/core/v1';
import type { Chart } from '@pulumi/kubernetes/helm/v4';
import type { input } from '@pulumi/kubernetes/types';
import type { Output } from '@pulumi/pulumi';
import { Config } from '@pulumi/pulumi';
import type { ATCGatewayInputs, ATCGatewayOutputs } from './atc-gateway.ts';
import { createATCGateway } from './atc-gateway.ts';
import type { ATCDaemonEndpoint } from './build-alert-rules.ts';
import { createObservability } from './observability.ts';
import { requireAlertWebhook } from './require-alert-webhook.ts';

// cloudflared's release; bump deliberately
const cloudflaredImage = 'cloudflare/cloudflared:2026.9.3';

interface ClusterInputs {
  readonly kubeconfig: string;
  readonly tunnelToken: Output<string>;

  // set only after the operator checklist's approval step
  readonly atcGateway?: ATCGatewayInputs;
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
}

// Workloads on the geoffcloud k3s cluster (#6, #7, #8). Pulumi reaches the k3s API
// over the tailnet with the kubeconfig from op://cloud/k3s-kubeconfig.
export function createClusterWorkloads(inputs: ClusterInputs): ClusterOutputs {
  const cluster = new Provider('geoffcloud', { kubeconfig: inputs.kubeconfig });

  const ingress = new Namespace(
    'ingress',
    { metadata: { name: 'ingress' } },
    { provider: cluster },
  );

  const token = new Secret(
    'cloudflared-token',
    {
      metadata: { name: 'cloudflared-token', namespace: ingress.metadata.name },
      stringData: { token: inputs.tunnelToken },
    },
    { provider: cluster },
  );

  // The tunnel for every public hostname under geoff.cloud. The routes live in
  // Cloudflare (ZeroTrustTunnelCloudflaredConfig), so this needs only the token.
  const cloudflared = new Deployment(
    'cloudflared',
    {
      metadata: { name: 'cloudflared', namespace: ingress.metadata.name },
      spec: buildCloudflaredSpec(token.metadata.name),
    },
    { provider: cluster },
  );

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

  return {
    ingressNamespace: ingress.metadata.name,
    cloudflared,
    ...observability,
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

function buildCloudflaredSpec(tokenSecret: Output<string>): input.apps.v1.DeploymentSpec {
  return {
    replicas: 2,
    selector: { matchLabels: { app: 'cloudflared' } },
    template: {
      metadata: { labels: { app: 'cloudflared' } },
      spec: {
        containers: [
          {
            name: 'cloudflared',
            image: cloudflaredImage,
            args: ['tunnel', '--no-autoupdate', '--metrics', '0.0.0.0:2000', 'run'],
            env: [
              {
                name: 'TUNNEL_TOKEN',
                valueFrom: { secretKeyRef: { name: tokenSecret, key: 'token' } },
              },
            ],
            ports: [{ name: 'metrics', containerPort: 2000 }],
            livenessProbe: { httpGet: { path: '/ready', port: 2000 }, periodSeconds: 10 },
            resources: { requests: { cpu: '10m', memory: '32Mi' }, limits: { memory: '128Mi' } },
          },
        ],
      },
    },
  };
}

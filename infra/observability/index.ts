import type { Provider } from '@pulumi/kubernetes';
import type { Output } from '@pulumi/pulumi';
import type { ATCDaemonEndpoint } from '../inputs/index.ts';
import { createClusterObservability } from './create-cluster-observability.ts';
import { createHealthCheck } from './health-check.ts';

// the in-cluster stack's inputs; unset while the stack manages no cluster
interface ClusterObservabilityInputs {
  readonly provider: Provider;

  // In-cluster alerts reach Discord only after `pulumi config set discordAlerts true` (#29);
  // until then no Secret holds the webhook and Alertmanager sends nothing. The inputs group
  // reads ALERT_WEBHOOK_URL once for this and the external health check.
  readonly alertWebhookURL: string | undefined;

  // a TCP probe plus alert per atc daemon, set only with the gateway
  readonly atcDaemons: readonly ATCDaemonEndpoint[] | undefined;
}

interface ObservabilityInputs {
  readonly accountID: string;

  // the health-check Worker's alert webhook; without it, state changes show only in its logs
  readonly alertURL: string | undefined;

  // the URL the health check probes on the atc gateway, set only with the gateway
  readonly atcHealthURL: string | undefined;

  readonly cluster: ClusterObservabilityInputs | undefined;
}

interface ObservabilityOutputs {
  readonly grafanaURL?: string;
  readonly grafanaAdminPassword?: Output<string>;
  readonly healthCheckCron: Output<{ cron: string }[]>;
}

// Observability: the in-cluster stack (#8), and the external health check (#8), a Worker that
// probes the public routes from outside
export async function createObservability(
  inputs: ObservabilityInputs,
): Promise<ObservabilityOutputs> {
  const cluster =
    inputs.cluster === undefined
      ? undefined
      : createClusterObservability(
          inputs.cluster.provider,
          inputs.cluster.alertWebhookURL,
          inputs.cluster.atcDaemons,
        );

  // ALERT_WEBHOOK_URL is optional; without it, state changes show only in the Worker's logs.
  const healthCheck = await createHealthCheck({
    accountID: inputs.accountID,
    targets: inputs.atcHealthURL === undefined ? [] : [{ name: 'atc', url: inputs.atcHealthURL }],
    alertURL: inputs.alertURL,
  });

  return {
    ...(cluster === undefined
      ? {}
      : { grafanaURL: cluster.grafanaURL, grafanaAdminPassword: cluster.grafanaAdminPassword }),
    healthCheckCron: healthCheck.schedules,
  };
}

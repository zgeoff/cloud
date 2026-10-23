import type { Provider } from '@pulumi/kubernetes';
import type { Output } from '@pulumi/pulumi';
import type { ATCDaemonEndpoint, AlertWebhook } from '../inputs/index.ts';
import { createClusterObservability } from './create-cluster-observability.ts';
import { createHealthCheck } from './health-check.ts';

interface ClusterObservabilityInputs {
  readonly provider: Provider;

  // In-cluster alerts reach Discord only after `pulumi config set discordAlerts true`; until
  // then no Secret holds the webhook and Alertmanager sends nothing.
  readonly alertWebhook: AlertWebhook | undefined;

  readonly atcDaemons: readonly ATCDaemonEndpoint[] | undefined;

  readonly nixieReadinessURL: string | undefined;
}

interface ObservabilityInputs {
  readonly accountID: string;

  // without it, state changes show only in the Worker's logs
  readonly alertURL: string | undefined;

  readonly atcHealthURL: string | undefined;

  readonly cluster: ClusterObservabilityInputs | undefined;
}

interface ObservabilityOutputs {
  readonly grafanaURL?: string;
  readonly grafanaAdminPassword?: Output<string>;
  readonly healthCheckCron: Output<{ cron: string }[]>;
}

export async function createObservability(
  inputs: ObservabilityInputs,
): Promise<ObservabilityOutputs> {
  const cluster =
    inputs.cluster === undefined
      ? undefined
      : createClusterObservability(inputs.cluster.provider, inputs.cluster.alertWebhook, {
          atcDaemons: inputs.cluster.atcDaemons,
          nixieReadinessURL: inputs.cluster.nixieReadinessURL,
        });

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

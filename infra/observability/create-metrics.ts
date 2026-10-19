import type { Provider } from '@pulumi/kubernetes';
import type { Namespace } from '@pulumi/kubernetes/core/v1';
import { Chart } from '@pulumi/kubernetes/helm/v4';
import type { Output } from '@pulumi/pulumi';
import { buildAlertmanagerValues } from './build-alertmanager-values.ts';
import { buildMetricsValues } from './build-metrics-values.ts';
import { createAlertWebhook } from './create-alert-webhook.ts';
import { makeDeleteBeforeReplaceTransform } from './make-delete-before-replace-transform.ts';

interface MetricsInputs {
  readonly grafanaPassword: Output<string>;
  readonly grafanaNodePort: number;
  readonly alertWebhookURL: string | undefined;
}

export function createMetrics(ns: Namespace, inputs: MetricsInputs, cluster: Provider): Chart {
  const webhook =
    inputs.alertWebhookURL === undefined
      ? undefined
      : createAlertWebhook(ns, inputs.alertWebhookURL, cluster);

  return new Chart(
    'kube-prometheus-stack',
    {
      namespace: ns.metadata.name,
      chart: 'kube-prometheus-stack',
      version: '91.8.2',
      repositoryOpts: { repo: 'https://prometheus-community.github.io/helm-charts' },
      values: {
        ...buildMetricsValues({
          password: inputs.grafanaPassword,
          nodePort: inputs.grafanaNodePort,
        }),
        alertmanager: buildAlertmanagerValues(webhook),
      },
    },

    // The Alertmanager pod mounts the webhook's Secret, so the Secret comes first. A change to
    // Alertmanager's config replaces the chart's fixed-name Secret, so the old one goes first.
    {
      provider: cluster,
      dependsOn: webhook === undefined ? [] : [webhook.resource],
      transforms: [makeDeleteBeforeReplaceTransform(cluster)],
    },
  );
}

const nullReceiver = 'null';
const discordReceiver = 'discord';

// the Secret that holds the Discord webhook, and the file Alertmanager reads it from
interface AlertWebhookMount {
  readonly secretName: string;
  readonly file: string;
}

interface Receiver {
  readonly name: string;
  readonly discord_configs?: readonly {
    readonly webhook_url_file: string;
    readonly send_resolved: boolean;
  }[];
}

interface AlertmanagerValues {
  readonly enabled: true;
  readonly config: {
    readonly route: {
      readonly receiver: string;
      readonly routes: readonly { readonly receiver: string; readonly matchers: string[] }[];
    };
    readonly receivers: readonly Receiver[];
  };
  readonly alertmanagerSpec: {
    readonly secrets: readonly string[];
    readonly resources: Record<string, Record<string, string>>;
  };
}

// kube-prometheus-stack's `alertmanager` values (#29). Helm merges `config` over the
// chart's default config, which keeps its global, inhibit_rules and templates; route and
// receivers are given whole here.
//
// Without a webhook every alert goes to the null receiver: Alertmanager runs and shows
// alerts, but sends nothing. With one, every alert goes to Discord except the chart's
// Watchdog (always firing, a dead man's switch) and InfoInhibitor (a helper). The URL
// itself never enters the values, only the path of the mounted Secret's file.
export function buildAlertmanagerValues(
  webhook: AlertWebhookMount | undefined,
): AlertmanagerValues {
  const discord =
    webhook === undefined
      ? []
      : [
          {
            name: discordReceiver,
            discord_configs: [{ webhook_url_file: webhook.file, send_resolved: true }],
          },
        ];

  return {
    enabled: true,
    config: {
      route: {
        receiver: webhook === undefined ? nullReceiver : discordReceiver,
        routes: [{ receiver: nullReceiver, matchers: ['alertname =~ "Watchdog|InfoInhibitor"'] }],
      },
      receivers: [{ name: nullReceiver }, ...discord],
    },

    // silences and notification state live in an emptyDir: a restart forgets them
    alertmanagerSpec: {
      secrets: webhook === undefined ? [] : [webhook.secretName],
      resources: { requests: { cpu: '10m', memory: '32Mi' }, limits: { memory: '128Mi' } },
    },
  };
}

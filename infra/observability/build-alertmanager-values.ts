import { buildATCSignInRules } from './build-atc-sign-in-rules.ts';

const nullReceiver = 'null';
const discordReceiver = 'discord';
const signInReceiver = 'discord-sign-in';

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

interface Route {
  readonly receiver: string;
  readonly matchers: string[];
  readonly group_by?: string[];
  readonly group_wait?: string;
  readonly group_interval?: string;
  readonly repeat_interval?: string;
}

interface AlertmanagerValues {
  readonly enabled: true;
  readonly config: {
    readonly route: {
      readonly receiver: string;
      readonly routes: readonly Route[];
    };
    readonly receivers: readonly Receiver[];
  };
  readonly alertmanagerSpec: {
    readonly secrets: readonly string[];
    readonly resources: Record<string, Record<string, string>>;
  };
}

// kube-prometheus-stack's `alertmanager` values (#29); Helm merges `config` over chart defaults, keeping
// global/inhibit_rules/templates, with route and receivers given whole. Without a webhook all alerts go to
// null; with one, all but Watchdog/InfoInhibitor go to Discord via the mounted Secret's file.
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
          {
            name: signInReceiver,
            discord_configs: [{ webhook_url_file: webhook.file, send_resolved: false }],
          },
        ];

  return {
    enabled: true,
    config: {
      route: {
        receiver: webhook === undefined ? nullReceiver : discordReceiver,
        routes: [
          { receiver: nullReceiver, matchers: ['alertname =~ "Watchdog|InfoInhibitor"'] },
          ...(webhook === undefined ? [] : [buildSignInRoute()]),
        ],
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

// The atc sign-in alerts, one message per alert name, so a flood of one category never buries
// another. An alert ends when its window passes with no event, which is no news, so the route
// sends no resolved message.
function buildSignInRoute(): Route {
  const names = buildATCSignInRules().rules.map((rule) => rule.alert);

  return {
    receiver: signInReceiver,
    matchers: [`alertname =~ "${names.join('|')}"`],
    group_by: ['alertname'],
    group_wait: '30s',
    group_interval: '5m',
    repeat_interval: '1h',
  };
}

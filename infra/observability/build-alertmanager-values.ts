import { buildATCSignInRules } from './build-atc-sign-in-rules.ts';

const nullReceiver = 'null';
const discordReceiver = 'discord';
const signInReceiver = 'discord-sign-in';

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

            // a sign-in alert ends when its window passes with no event, which is no news
            discord_configs: [{ webhook_url_file: webhook.file, send_resolved: false }],
          },
        ];

  return {
    enabled: true,

    // Helm merges `config` over the chart's defaults, keeping global, inhibit_rules and templates,
    // so route and receivers are given whole.
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

function buildSignInRoute(): Route {
  const names = buildATCSignInRules().rules.map((rule) => rule.alert);

  return {
    receiver: signInReceiver,
    matchers: [`alertname =~ "${names.join('|')}"`],

    // one message per alert name, so a flood of one category never buries another
    group_by: ['alertname'],
    group_wait: '30s',
    group_interval: '5m',
    repeat_interval: '1h',
  };
}

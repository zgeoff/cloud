import { buildATCSignInRules } from './build-atc-sign-in-rules.ts';

const nullReceiver = 'null';
const discordReceiver = 'discord';
const criticalReceiver = 'discord-critical';
const signInReceiver = 'discord-sign-in';

// Discord cuts an embed title at 256 runes. The default title lists every common label, so this
// one holds the status, the alert name and the namespace, each cut to a length that sums below it.
const title =
  '[{{ .Status | toUpper }}{{ if eq .Status "firing" }}:{{ .Alerts.Firing | len }}{{ end }}] ' +
  '{{ with .CommonLabels.alertname }}{{ reReplaceAll "(?s)^(.{0,150}).*$" "$1" . }}' +
  '{{ else }}{{ len .Alerts }} alerts{{ end }}' +
  '{{ with .GroupLabels.namespace }} in {{ reReplaceAll "(?s)^(.{0,63}).*$" "$1" . }}{{ end }}';

interface AlertWebhookMount {
  readonly secretName: string;
  readonly file: string;
  readonly mentionTemplateFile: string;
}

interface Receiver {
  readonly name: string;
  readonly discord_configs?: readonly {
    readonly webhook_url_file: string;
    readonly send_resolved: boolean;
    readonly title?: string;
    readonly content?: string;
  }[];
}

interface Route {
  readonly receiver: string;
  readonly matchers: string[];
  readonly continue?: boolean;
  readonly group_by?: string[];
  readonly group_wait?: string;
  readonly group_interval?: string;
  readonly repeat_interval?: string;
}

interface AlertmanagerValues {
  readonly enabled: true;
  readonly config: {
    readonly route: Omit<Route, 'matchers' | 'continue'> & { readonly routes: readonly Route[] };
    readonly receivers: readonly Receiver[];
    readonly templates?: readonly string[];
  };
  readonly alertmanagerSpec: {
    readonly secrets: readonly string[];
    readonly resources: Record<string, Record<string, string>>;
  };
}

const rootGrouping = {
  group_by: ['namespace'],
  group_wait: '30s',
  group_interval: '5m',
  repeat_interval: '12h',
};

export function buildAlertmanagerValues(
  webhook: AlertWebhookMount | undefined,
): AlertmanagerValues {
  return {
    enabled: true,

    // Helm merges `config` over the chart's defaults key by key, keeping global and inhibit_rules,
    // and replaces each list. The route gives the chart's grouping itself, so a test of these
    // values runs the route the cluster runs.
    config:
      webhook === undefined
        ? {
            route: { receiver: nullReceiver, ...rootGrouping, routes: [buildNullRoute()] },
            receivers: [{ name: nullReceiver }],
          }
        : {
            route: {
              receiver: discordReceiver,
              ...rootGrouping,
              routes: [
                buildNullRoute(),

                // a critical alert also reaches the routes below, so the discord receiver keeps it
                { receiver: criticalReceiver, matchers: ['severity = "critical"'], continue: true },
                buildSignInRoute(),

                // once a route has matched, an alert never falls back to the root's receiver
                { receiver: discordReceiver, matchers: [] },
              ],
            },
            receivers: [
              { name: nullReceiver },
              {
                name: discordReceiver,
                discord_configs: [{ webhook_url_file: webhook.file, send_resolved: true, title }],
              },
              {
                name: criticalReceiver,

                // the discord receiver posts the resolve; the mention is for a firing alert only
                discord_configs: [
                  {
                    webhook_url_file: webhook.file,
                    send_resolved: false,
                    title,
                    content: '{{ template "discord.mention" . }}',
                  },
                ],
              },
              {
                name: signInReceiver,

                // A sign-in alert ends when its window passes with no event, which is no news. Its
                // labels come from closed sets, so the default title stays short.
                discord_configs: [{ webhook_url_file: webhook.file, send_resolved: false }],
              },
            ],
            templates: ['/etc/alertmanager/config/*.tmpl', webhook.mentionTemplateFile],
          },

    // silences and notification state live in an emptyDir: a restart forgets them
    alertmanagerSpec: {
      secrets: webhook === undefined ? [] : [webhook.secretName],
      resources: { requests: { cpu: '10m', memory: '32Mi' }, limits: { memory: '128Mi' } },
    },
  };
}

function buildNullRoute(): Route {
  return { receiver: nullReceiver, matchers: ['alertname =~ "Watchdog|InfoInhibitor"'] };
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

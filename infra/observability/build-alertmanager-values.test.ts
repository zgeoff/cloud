import { expect, test } from 'bun:test';
import { buildAlertmanagerValues } from './build-alertmanager-values.ts';

test('it routes every alert to the null receiver and mounts nothing without a webhook', () => {
  expect(buildAlertmanagerValues(undefined)).toStrictEqual({
    enabled: true,
    config: {
      route: {
        receiver: 'null',
        group_by: ['namespace'],
        group_wait: '30s',
        group_interval: '5m',
        repeat_interval: '12h',
        routes: [{ receiver: 'null', matchers: ['alertname =~ "Watchdog|InfoInhibitor"'] }],
      },
      receivers: [{ name: 'null' }],
    },
    alertmanagerSpec: {
      secrets: [],
      resources: { requests: { cpu: '10m', memory: '32Mi' }, limits: { memory: '128Mi' } },
    },
  });
});

test('it routes alerts to Discord through the mounted Secret, a critical alert also to a receiver that mentions the user, Watchdog and InfoInhibitor to null, and the atc sign-in alerts grouped by name without resolved messages, when a webhook is given', () => {
  const title =
    '[{{ .Status | toUpper }}{{ if eq .Status "firing" }}:{{ .Alerts.Firing | len }}{{ end }}] {{ with .CommonLabels.alertname }}{{ reReplaceAll "(?s)^(.{0,150}).*$" "$1" . }}{{ else }}{{ len .Alerts }} alerts{{ end }}{{ with .GroupLabels.namespace }} in {{ reReplaceAll "(?s)^(.{0,63}).*$" "$1" . }}{{ end }}';

  expect(
    buildAlertmanagerValues({
      secretName: 'alertmanager-discord',
      file: '/etc/alertmanager/secrets/alertmanager-discord/webhook-url',
      mentionTemplateFile: '/etc/alertmanager/secrets/alertmanager-discord/mention.tmpl',
    }),
  ).toStrictEqual({
    enabled: true,
    config: {
      route: {
        receiver: 'discord',
        group_by: ['namespace'],
        group_wait: '30s',
        group_interval: '5m',
        repeat_interval: '12h',
        routes: [
          { receiver: 'null', matchers: ['alertname =~ "Watchdog|InfoInhibitor"'] },
          { receiver: 'discord-critical', matchers: ['severity = "critical"'], continue: true },
          {
            receiver: 'discord-sign-in',
            matchers: [
              'alertname =~ "ATCGatewaySignInStarted|ATCGatewaySignInRateLimited|ATCGatewayInvalidSignInRequests|ATCGatewayOwnerSignedIn|ATCGatewayOwnerAuthFailed|ATCGatewayConsentAllowed|ATCGatewayConsentDenied|ATCGatewaySecurityEventsSuppressed|ATCGatewayUnrecognizedSecurityEvents"',
            ],
            group_by: ['alertname'],
            group_wait: '30s',
            group_interval: '5m',
            repeat_interval: '1h',
          },
          { receiver: 'discord', matchers: [] },
        ],
      },
      receivers: [
        { name: 'null' },
        {
          name: 'discord',
          discord_configs: [
            {
              webhook_url_file: '/etc/alertmanager/secrets/alertmanager-discord/webhook-url',
              send_resolved: true,
              title,
            },
          ],
        },
        {
          name: 'discord-critical',
          discord_configs: [
            {
              webhook_url_file: '/etc/alertmanager/secrets/alertmanager-discord/webhook-url',
              send_resolved: false,
              title,
              content: '{{ template "discord.mention" . }}',
            },
          ],
        },
        {
          name: 'discord-sign-in',
          discord_configs: [
            {
              webhook_url_file: '/etc/alertmanager/secrets/alertmanager-discord/webhook-url',
              send_resolved: false,
            },
          ],
        },
      ],
      templates: [
        '/etc/alertmanager/config/*.tmpl',
        '/etc/alertmanager/secrets/alertmanager-discord/mention.tmpl',
      ],
    },
    alertmanagerSpec: {
      secrets: ['alertmanager-discord'],
      resources: { requests: { cpu: '10m', memory: '32Mi' }, limits: { memory: '128Mi' } },
    },
  });
});

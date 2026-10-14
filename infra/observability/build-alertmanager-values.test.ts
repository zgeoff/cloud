import { expect, test } from 'bun:test';
import { buildAlertmanagerValues } from './build-alertmanager-values.ts';

test('it routes every alert to the null receiver and mounts nothing without a webhook', () => {
  expect(buildAlertmanagerValues(undefined)).toStrictEqual({
    enabled: true,
    config: {
      route: {
        receiver: 'null',
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

test('it routes alerts to Discord through the mounted Secret, Watchdog and InfoInhibitor to null, when a webhook is given', () => {
  expect(
    buildAlertmanagerValues({
      secretName: 'alertmanager-discord',
      file: '/etc/alertmanager/secrets/alertmanager-discord/webhook-url',
    }),
  ).toStrictEqual({
    enabled: true,
    config: {
      route: {
        receiver: 'discord',
        routes: [{ receiver: 'null', matchers: ['alertname =~ "Watchdog|InfoInhibitor"'] }],
      },
      receivers: [
        { name: 'null' },
        {
          name: 'discord',
          discord_configs: [
            {
              webhook_url_file: '/etc/alertmanager/secrets/alertmanager-discord/webhook-url',
              send_resolved: true,
            },
          ],
        },
      ],
    },
    alertmanagerSpec: {
      secrets: ['alertmanager-discord'],
      resources: { requests: { cpu: '10m', memory: '32Mi' }, limits: { memory: '128Mi' } },
    },
  });
});

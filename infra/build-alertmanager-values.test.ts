import { describe, expect, test } from 'bun:test';
import { buildAlertmanagerValues } from './build-alertmanager-values.ts';

const webhook = {
  secretName: 'alertmanager-discord',
  file: '/etc/alertmanager/secrets/alertmanager-discord/webhook-url',
};

describe('buildAlertmanagerValues', () => {
  test('routes every alert to the null receiver and mounts nothing without a webhook', () => {
    const values = buildAlertmanagerValues(undefined);

    expect(values.enabled).toBe(true);
    expect(values.config.route.receiver).toBe('null');
    expect(values.config.receivers).toEqual([{ name: 'null' }]);
    expect(values.alertmanagerSpec.secrets).toEqual([]);
    expect(JSON.stringify(values)).not.toContain('discord');
  });

  test('routes alerts to Discord through the mounted Secret when a webhook is given', () => {
    const values = buildAlertmanagerValues(webhook);

    expect(values.config.route.receiver).toBe('discord');

    expect(values.config.receivers).toContainEqual({
      name: 'discord',
      discord_configs: [{ webhook_url_file: webhook.file, send_resolved: true }],
    });

    expect(values.alertmanagerSpec.secrets).toEqual(['alertmanager-discord']);
  });

  test('keeps the null receiver for Watchdog and InfoInhibitor in both modes', () => {
    for (const values of [buildAlertmanagerValues(undefined), buildAlertmanagerValues(webhook)]) {
      expect(values.config.receivers).toContainEqual({ name: 'null' });

      expect(values.config.route.routes).toEqual([
        { receiver: 'null', matchers: ['alertname =~ "Watchdog|InfoInhibitor"'] },
      ]);
    }
  });
});

import { describe, expect, test } from 'bun:test';
import { requireAlertWebhook } from './require-alert-webhook.ts';

const webhook = 'https://example.invalid/webhook';

describe('requireAlertWebhook', () => {
  test('leaves the webhook out while the flag is off, even when it is set', () => {
    expect(requireAlertWebhook(false, webhook)).toBeUndefined();
    expect(requireAlertWebhook(false, undefined)).toBeUndefined();
  });

  test('returns the webhook when the flag is on', () => {
    expect(requireAlertWebhook(true, webhook)).toBe(webhook);
  });

  test('throws when the flag is on and the webhook is missing or blank', () => {
    expect(() => requireAlertWebhook(true, undefined)).toThrow('ALERT_WEBHOOK_URL is empty');
    expect(() => requireAlertWebhook(true, ' \n')).toThrow('ALERT_WEBHOOK_URL is empty');
  });
});

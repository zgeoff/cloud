import { expect, test } from 'bun:test';
import { requireAlertWebhook } from './require-alert-webhook.ts';

test('it leaves the webhook out while the flag is off, even when it is set', () => {
  expect(requireAlertWebhook(false, 'https://example.invalid/webhook')).toBeUndefined();
});

test('it leaves the webhook out while the flag is off and it is unset', () => {
  expect(requireAlertWebhook(false, undefined)).toBeUndefined();
});

test('it returns the webhook when the flag is on', () => {
  expect(requireAlertWebhook(true, 'https://example.invalid/webhook')).toBe(
    'https://example.invalid/webhook',
  );
});

test('it returns the webhook untrimmed', () => {
  expect(requireAlertWebhook(true, ' https://example.invalid/webhook\n')).toBe(
    ' https://example.invalid/webhook\n',
  );
});

test.each([
  ['missing', undefined],
  ['empty', ''],
  ['blank', ' \n'],
])('it throws when the flag is on and the webhook is %s', (_kind, webhookURL) => {
  expect(() => requireAlertWebhook(true, webhookURL)).toThrowWithMessage(
    Error,
    'discordAlerts is on, but ALERT_WEBHOOK_URL is empty; run through `op run --env-file=../.env`',
  );
});

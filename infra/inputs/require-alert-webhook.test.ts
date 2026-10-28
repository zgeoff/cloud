import { expect, test } from 'bun:test';
import { requireAlertWebhook } from './require-alert-webhook.ts';

test('it leaves the webhook out while the flag is off, even when it is set', () => {
  expect(
    requireAlertWebhook(false, 'https://example.invalid/webhook', '100000000000000001'),
  ).toBeUndefined();
});

test('it leaves the webhook out while the flag is off and it is unset', () => {
  expect(requireAlertWebhook(false, undefined, undefined)).toBeUndefined();
});

test('it returns the webhook and the user to mention when the flag is on', () => {
  expect(
    requireAlertWebhook(true, 'https://example.invalid/webhook', '100000000000000001'),
  ).toStrictEqual({ url: 'https://example.invalid/webhook', mentionUserID: '100000000000000001' });
});

test('it throws when the flag is on and the webhook is unset', () => {
  expect(() => requireAlertWebhook(true, undefined, '100000000000000001')).toThrowWithMessage(
    Error,
    'discordAlerts is on, but ALERT_WEBHOOK_URL is empty; run through `op run --env-file=../.env`',
  );
});

test('it throws when the flag is on and the user to mention is unset', () => {
  expect(() =>
    requireAlertWebhook(true, 'https://example.invalid/webhook', undefined),
  ).toThrowWithMessage(
    Error,
    'discordAlerts is on, but ALERT_MENTION_USER_ID is empty; run through `op run --env-file=../.env`',
  );
});

test('it throws when the user to mention holds more than digits', () => {
  expect(() =>
    requireAlertWebhook(true, 'https://example.invalid/webhook', '1{{ end }}'),
  ).toThrowWithMessage(
    Error,
    'ALERT_MENTION_USER_ID is not a Discord user ID: it holds a non-digit',
  );
});

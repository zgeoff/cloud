import { expect, test } from 'bun:test';
import { findAlertURL } from './find-alert-url.ts';

test('it returns the webhook URL', () => {
  expect(findAlertURL({ ALERT_WEBHOOK_URL: 'https://discord.com/api/webhooks/1/abc' })).toBe(
    'https://discord.com/api/webhooks/1/abc',
  );
});

test('it trims the webhook URL', () => {
  expect(findAlertURL({ ALERT_WEBHOOK_URL: ' https://discord.com/api/webhooks/1/abc\n' })).toBe(
    'https://discord.com/api/webhooks/1/abc',
  );
});

test.each([
  ['unset', {}],
  ['empty', { ALERT_WEBHOOK_URL: '' }],
  ['blank', { ALERT_WEBHOOK_URL: ' \n' }],
])('it reads a webhook URL that is %s as undefined', (_kind, env) => {
  expect(findAlertURL(env)).toBeUndefined();
});

import { expect, test } from 'bun:test';
import { buildAlertWebhookData } from './build-alert-webhook-data.ts';
import { buildSecretChecksum } from './build-secret-checksum.ts';

test('it holds the webhook URL and the mention template under their keys, with the checksum of both', () => {
  expect(
    buildAlertWebhookData(
      { url: 'https://example.invalid/api/webhooks/1/token', mentionUserID: '100000000000000001' },
      { url: 'webhook-url', mention: 'mention.tmpl' },
    ),
  ).toStrictEqual({
    data: {
      'webhook-url': 'https://example.invalid/api/webhooks/1/token',
      'mention.tmpl': '{{ define "discord.mention" }}<@100000000000000001>{{ end }}\n',
    },
    checksum: buildSecretChecksum({
      'webhook-url': 'https://example.invalid/api/webhooks/1/token',
      'mention.tmpl': '{{ define "discord.mention" }}<@100000000000000001>{{ end }}\n',
    }),
  });
});

test('it gives another user to mention another checksum', () => {
  expect(
    buildAlertWebhookData(
      { url: 'https://example.invalid/api/webhooks/1/token', mentionUserID: '100000000000000001' },
      { url: 'webhook-url', mention: 'mention.tmpl' },
    ).checksum,
  ).not.toBe(
    buildAlertWebhookData(
      { url: 'https://example.invalid/api/webhooks/1/token', mentionUserID: '100000000000000002' },
      { url: 'webhook-url', mention: 'mention.tmpl' },
    ).checksum,
  );
});

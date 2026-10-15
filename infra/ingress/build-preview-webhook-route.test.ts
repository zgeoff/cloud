import { expect, test } from 'bun:test';
import { buildPreviewWebhookRoute } from './build-preview-webhook-route.ts';

test("it routes only the webhook path of the registry's hostname to the host's webhook listener", () => {
  expect(buildPreviewWebhookRoute()).toStrictEqual({
    hostname: 'preview-webhook.geoff.cloud',
    service: 'http://100.69.47.33:8418',
    path: '^/webhook$',
  });
});

test('it builds a path rule that matches /webhook and no other path', () => {
  const route = buildPreviewWebhookRoute();

  const pattern = new RegExp(route.path ?? '', 'u');

  expect(
    ['/webhook', '/webhook/', '/webhooks', '/x/webhook', '/'].filter((path) => pattern.test(path)),
  ).toStrictEqual(['/webhook']);
});

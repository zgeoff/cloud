import { expect, test } from 'bun:test';
import { getResponse } from 'msw';
import { alertWebhookURL } from './alert-webhook-url.ts';
import { handlers } from './handlers.ts';
import { sentAlerts } from './sent-alerts.ts';
import { targetStatuses } from './target-statuses.ts';

test('it answers a probe of a target with the status stored for its URL', async () => {
  targetStatuses.set('https://atc.geoff.cloud/', 530);

  const response = await getResponse(handlers, new Request('https://atc.geoff.cloud/'));

  expect(response?.status).toBe(530);
});

test('it sends a Location header with a redirect status', async () => {
  targetStatuses.set('https://atc.geoff.cloud/', 301);

  const response = await getResponse(handlers, new Request('https://atc.geoff.cloud/'));

  expect(response?.headers.get('location')).toBe('https://example.invalid/');
});

test('it leaves a probe of a URL with no stored status unhandled', async () => {
  targetStatuses.set('https://atc.geoff.cloud/', 200);

  const response = await getResponse(handlers, new Request('https://imp.geoff.cloud/'));

  expect(response).toBeUndefined();
});

test("it records each alert's content type and body, and answers it with 204", async () => {
  const response = await getResponse(
    handlers,
    new Request(alertWebhookURL, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: '{"content":"down"}',
    }),
  );

  expect({ status: response?.status, sentAlerts }).toStrictEqual({
    status: 204,
    sentAlerts: [{ contentType: 'application/json', body: '{"content":"down"}' }],
  });
});

import { expect, test } from 'bun:test';
import { createHmac } from 'node:crypto';
import { verifyWebhookSignature } from './verify-webhook-signature.ts';

test('it accepts the HMAC-SHA256 of the body under the secret', async () => {
  const body = new TextEncoder().encode('{"action":"opened"}');

  const header = `sha256=${createHmac('sha256', 'stub-webhook-secret').update(body).digest('hex')}`;

  const result = await verifyWebhookSignature('stub-webhook-secret', body.buffer, header);

  expect(result).toBeTrue();
});

test('it rejects a signature made with another secret', async () => {
  const body = new TextEncoder().encode('{"action":"opened"}');

  const header = `sha256=${createHmac('sha256', 'a-guessed-secret').update(body).digest('hex')}`;

  const result = await verifyWebhookSignature('stub-webhook-secret', body.buffer, header);

  expect(result).toBeFalse();
});

test('it rejects a delivery with no signature', async () => {
  const body = new TextEncoder().encode('{"action":"opened"}');

  const result = await verifyWebhookSignature('stub-webhook-secret', body.buffer, null);

  expect(result).toBeFalse();
});

test.each([
  ['the SHA-1 header form', 'sha1=0a4d55a8d778e5022fab701977c5d840bbc486d0'],
  ['a digest that is not hex', `sha256=${'z'.repeat(64)}`],
  ['a digest one byte short', `sha256=${'0'.repeat(62)}`],
])('it rejects %s', async (_label, header) => {
  const body = new TextEncoder().encode('{"action":"opened"}');

  const result = await verifyWebhookSignature('stub-webhook-secret', body.buffer, header);

  expect(result).toBeFalse();
});

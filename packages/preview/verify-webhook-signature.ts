export async function verifyWebhookSignature(
  secret: string,
  body: ArrayBuffer,
  header: string | null,
): Promise<boolean> {
  // GitHub's `X-Hub-Signature-256: sha256=<hex>`, an HMAC-SHA256 of the raw body
  // (https://docs.github.com/en/webhooks/using-webhooks/validating-webhook-deliveries)
  const hex = header?.startsWith('sha256=') === true ? header.slice('sha256='.length) : null;

  if (hex === null || !/^[\da-f]{64}$/u.test(hex)) {
    return false;
  }

  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['verify'],
  );

  // Web Crypto's verify compares in constant time
  return crypto.subtle.verify('HMAC', key, Buffer.from(hex, 'hex'), body);
}

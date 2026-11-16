import { expect, test } from 'bun:test';
import { parseTokenRequest } from './parse-token-request.ts';

test("it parses the token and its expiry from kubectl's TokenRequest", () => {
  // the shape kubectl 1.35 prints for `create token --output json`
  const text = JSON.stringify({
    kind: 'TokenRequest',
    apiVersion: 'authentication.k8s.io/v1',
    metadata: { name: 'nixie-verify', namespace: 'nixie' },
    spec: { audiences: ['https://kubernetes.default.svc.cluster.local', 'k3s'] },
    status: { token: 'fake-token-for-tests', expirationTimestamp: '2026-11-15T06:34:02Z' },
  });

  expect(parseTokenRequest(text)).toStrictEqual({
    token: 'fake-token-for-tests',
    expiresAt: '2026-11-15T06:34:02Z',
  });
});

test.each([
  ['text that is not JSON', 'error: failed to create token'],
  [
    'a TokenRequest with no token',
    JSON.stringify({ status: { token: '', expirationTimestamp: '2026-11-15T06:34:02Z' } }),
  ],
])('it parses nothing from %s', (_title, text) => {
  expect(parseTokenRequest(text)).toBeNull();
});

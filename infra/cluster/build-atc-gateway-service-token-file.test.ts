import { expect, test } from 'bun:test';
import { buildATCGatewayServiceTokenFile } from './build-atc-gateway-service-token-file.ts';

test('#buildATCGatewayServiceTokenFile names the public URL and /mcp as the resource and gives the boxxy client its four scopes and its one token', () => {
  const token = `atcs_${'a'.repeat(40)}`;

  expect(
    JSON.parse(
      buildATCGatewayServiceTokenFile({
        publicURL: 'https://atc.geoff.cloud',
        tokens: { boxxy: token },
      }),
    ),
  ).toStrictEqual({
    resource: 'https://atc.geoff.cloud/mcp',
    clients: { boxxy: { scopes: ['read', 'spawn', 'message', 'kill'], tokens: [token] } },
  });
});

test('#buildATCGatewayServiceTokenFile takes the origin of a public URL with a trailing slash, as atc does', () => {
  const token = `atcs_${'a'.repeat(40)}`;

  expect(
    JSON.parse(
      buildATCGatewayServiceTokenFile({
        publicURL: 'https://atc.geoff.cloud/',
        tokens: { boxxy: token },
      }),
    ),
  ).toMatchObject({ resource: 'https://atc.geoff.cloud/mcp' });
});

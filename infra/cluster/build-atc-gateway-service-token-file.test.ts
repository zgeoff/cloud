import { expect, test } from 'bun:test';
import { buildATCGatewayServiceTokenFile } from './build-atc-gateway-service-token-file.ts';

test('#buildATCGatewayServiceTokenFile names the public URL and /mcp as the resource and gives the boxxy client its four scopes and its one token', () => {
  const token = `atcs_${'a'.repeat(40)}`;

  expect(
    JSON.parse(
      buildATCGatewayServiceTokenFile({
        publicURL: 'https://atc.geoff.cloud',
        tokens: { boxxy: token },
        secretDigests: {},
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
        secretDigests: {},
      }),
    ),
  ).toMatchObject({ resource: 'https://atc.geoff.cloud/mcp' });
});

test('#buildATCGatewayServiceTokenFile gives the boxxy-notices client the message scope alone, beside the boxxy client', () => {
  const token = `atcs_${'a'.repeat(40)}`;
  const noticeToken = `atcs_${'n'.repeat(40)}`;

  expect(
    JSON.parse(
      buildATCGatewayServiceTokenFile({
        publicURL: 'https://atc.geoff.cloud',
        tokens: { boxxy: token, 'boxxy-notices': noticeToken },
        secretDigests: {},
      }),
    ),
  ).toStrictEqual({
    resource: 'https://atc.geoff.cloud/mcp',
    clients: {
      boxxy: { scopes: ['read', 'spawn', 'message', 'kill'], tokens: [token] },
      'boxxy-notices': { scopes: ['message'], tokens: [noticeToken] },
    },
  });
});

test('#buildATCGatewayServiceTokenFile gives the nixie client the read, spawn, message and kill scopes and its one token', () => {
  const nixieToken = `atcs_${'x'.repeat(40)}`;

  expect(
    JSON.parse(
      buildATCGatewayServiceTokenFile({
        publicURL: 'https://atc.geoff.cloud',
        tokens: { nixie: nixieToken },
        secretDigests: {},
      }),
    ),
  ).toStrictEqual({
    resource: 'https://atc.geoff.cloud/mcp',
    clients: { nixie: { scopes: ['read', 'spawn', 'message', 'kill'], tokens: [nixieToken] } },
  });
});

test('#buildATCGatewayServiceTokenFile gives each client of a secret digest the read scope alone and its one digest, beside the token clients', () => {
  const token = `atcs_${'a'.repeat(40)}`;
  const firstDigest = '1'.repeat(64);
  const secondDigest = '2'.repeat(64);

  expect(
    JSON.parse(
      buildATCGatewayServiceTokenFile({
        publicURL: 'https://atc.geoff.cloud',
        tokens: { boxxy: token },
        secretDigests: { 'reader-one': firstDigest, 'reader-two': secondDigest },
      }),
    ),
  ).toStrictEqual({
    resource: 'https://atc.geoff.cloud/mcp',
    clients: {
      boxxy: { scopes: ['read', 'spawn', 'message', 'kill'], tokens: [token] },
      'reader-one': { scopes: ['read'], secretDigests: [firstDigest] },
      'reader-two': { scopes: ['read'], secretDigests: [secondDigest] },
    },
  });
});

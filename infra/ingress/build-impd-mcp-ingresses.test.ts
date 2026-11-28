import { expect, test } from 'bun:test';
import { buildImpdMCPIngresses } from './build-impd-mcp-ingresses.ts';

test("it sends impd's listed paths to its public listener on the host's loopback, then answers 404", () => {
  expect(buildImpdMCPIngresses('impz.geoff.cloud')).toStrictEqual([
    {
      hostname: 'impz.geoff.cloud',
      path: String.raw`^(?:/mcp|/\.well-known/oauth-authorization-server|/\.well-known/oauth-protected-resource|/\.well-known/oauth-protected-resource/mcp|/oauth2/authorize|/oauth2/token|/oauth2/revoke|/login|/enroll|/consent|/error)$`,
      service: 'http://127.0.0.1:7071',
    },
    { service: 'http_status:404' },
  ]);
});

test.each(['/mcp', '/oauth2/token', '/login', '/.well-known/oauth-protected-resource/mcp'])(
  'it passes the listed path %s',
  (path: string) => {
    const [rule] = buildImpdMCPIngresses('impz.geoff.cloud');

    expect(new RegExp(rule?.path ?? '', 'u').test(path)).toBe(true);
  },
);

test.each(['/', '/mcp/', '/MCP', '/login/', '/rpc', '/rpc/imp/list', '/health', '/oauth2/token/x'])(
  'it leaves the unlisted path %s to the 404 rule',
  (path: string) => {
    const [rule] = buildImpdMCPIngresses('impz.geoff.cloud');

    expect(new RegExp(rule?.path ?? '', 'u').test(path)).toBe(false);
  },
);

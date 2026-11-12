import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildMockTunnelRoute } from '../test-utils/build-mock-tunnel-route.ts';
import { buildPepysAPIRoutes } from './build-pepys-api-routes.ts';
import { buildTunnelIngresses } from './build-tunnel-ingresses.ts';

test("it sends the API's browser paths through cloudflared's Access check, then its machine paths without one", () => {
  const service = 'http://pepys-host.pepys.svc.cluster.local:8081';
  const access = { teamName: output('example-team'), audience: output('0123456789abcdef') };

  expect(
    buildPepysAPIRoutes(buildMockTunnelRoute({ hostname: 'pepys.geoff.cloud', service }), access),
  ).toStrictEqual([
    {
      hostname: 'pepys.geoff.cloud',
      service,
      path: '^(?:/oauth2/authorize|/login|/enroll|/consent|/error)$',
      access,
    },
    {
      hostname: 'pepys.geoff.cloud',
      service,
      path: String.raw`^(?:/|/mcp|/oauth2/token|/oauth2/revoke|/\.well-known/oauth-authorization-server|/\.well-known/oauth-protected-resource|/\.well-known/oauth-protected-resource/mcp)$`,
    },
  ]);
});

test.each([
  ['GET /oauth2/authorize', '/oauth2/authorize'],
  ['GET /login and POST /login', '/login'],
  ['GET /enroll and POST /enroll', '/enroll'],
  ['GET /consent and POST /consent', '/consent'],
  ['GET /error', '/error'],
])('it sends %s to the Access-checked rule', (_route: string, path: string) => {
  const rules = buildTunnelIngresses(
    buildPepysAPIRoutes(buildMockTunnelRoute({ hostname: 'pepys.geoff.cloud' }), {
      teamName: output('example-team'),
      audience: output('0123456789abcdef'),
    }),
  );

  // cloudflared takes the first match, on the decoded path; RE2 and JavaScript agree on these
  // patterns' syntax
  const index = rules.findIndex(
    (rule) =>
      (rule.hostname === undefined || rule.hostname === 'pepys.geoff.cloud') &&
      (rule.path === undefined || new RegExp(rule.path, 'u').test(path)),
  );

  expect(rules[index]?.originRequest?.access.required).toBeTrue();
});

test.each([
  ['the MCP endpoint', '/mcp'],
  ["the MCP endpoint's alias", '/'],
  ['POST /oauth2/token', '/oauth2/token'],
  ['POST /oauth2/revoke', '/oauth2/revoke'],
  ['the authorization server metadata', '/.well-known/oauth-authorization-server'],
  ['the protected resource metadata', '/.well-known/oauth-protected-resource'],
  ["the MCP resource's metadata", '/.well-known/oauth-protected-resource/mcp'],
])('it sends %s to the rule without an Access check', (_route: string, path: string) => {
  const rules = buildTunnelIngresses(
    buildPepysAPIRoutes(buildMockTunnelRoute({ hostname: 'pepys.geoff.cloud' }), {
      teamName: output('example-team'),
      audience: output('0123456789abcdef'),
    }),
  );

  expect(
    rules.findIndex(
      (rule) =>
        (rule.hostname === undefined || rule.hostname === 'pepys.geoff.cloud') &&
        (rule.path === undefined || new RegExp(rule.path, 'u').test(path)),
    ),
  ).toBe(1);
});

test.each([
  ['the oRPC root', '/rpc'],
  ['the oRPC root with a slash', '/rpc/'],
  ['an oRPC procedure', '/rpc/entity/get'],
  ['an oRPC procedure under the MCP alias', '//rpc/entity/get'],
  ['an oRPC procedure behind a dot segment', '/mcp/../rpc/entity/get'],
  ['an oRPC procedure in another case', '/RPC/entity/get'],
  ['a trailing slash on the MCP endpoint', '/mcp/'],
  ['the MCP endpoint in another case', '/MCP'],
  ['a trailing slash on a browser path', '/login/'],
  ['a subpath of a machine route', '/mcp/login'],
  ['a matrix parameter', '/login;x'],
  ['the any-character dot of a pattern', '/Xwell-known/oauth-authorization-server'],
  ['a register path the API does not serve', '/oauth2/register'],
  ["better-auth's own sign-in path", '/api/auth/sign-in'],
])('it answers %s on the API hostname with the 404 catch-all', (_variant: string, path: string) => {
  const rules = buildTunnelIngresses(
    buildPepysAPIRoutes(buildMockTunnelRoute({ hostname: 'pepys.geoff.cloud' }), {
      teamName: output('example-team'),
      audience: output('0123456789abcdef'),
    }),
  );

  expect(
    rules.findIndex(
      (rule) =>
        (rule.hostname === undefined || rule.hostname === 'pepys.geoff.cloud') &&
        (rule.path === undefined || new RegExp(rule.path, 'u').test(path)),
    ),
  ).toBe(2);
});

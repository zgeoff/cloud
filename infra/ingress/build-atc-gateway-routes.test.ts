import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildMockTunnelRoute } from '../test-utils/build-mock-tunnel-route.ts';
import { buildATCGatewayRoutes } from './build-atc-gateway-routes.ts';
import { buildTunnelIngresses } from './build-tunnel-ingresses.ts';

const browserPattern = '^(?:/oauth2/authorize|/login|/enroll|/consent|/error)$';
const machinePattern = String.raw`^(?:/|/mcp|/oauth2/token|/oauth2/revoke|/\.well-known/oauth-authorization-server|/\.well-known/oauth-protected-resource|/\.well-known/oauth-protected-resource/mcp)$`;
const access = { teamName: output('example-team'), audience: output('0123456789abcdef') };

test("it sends the gateway's browser paths through cloudflared's Access check, then its machine paths without one", () => {
  const service = output('http://atc-gateway.atc.svc.cluster.local:8414');

  expect(
    buildATCGatewayRoutes(buildMockTunnelRoute({ hostname: 'atc.geoff.cloud', service }), access),
  ).toStrictEqual([
    { hostname: 'atc.geoff.cloud', service, path: browserPattern, access },
    { hostname: 'atc.geoff.cloud', service, path: machinePattern },
  ]);
});

function findRuleIndex(hostname: string, path: string): number {
  const gateway = buildATCGatewayRoutes(
    buildMockTunnelRoute({ hostname: 'atc.geoff.cloud' }),
    access,
  );

  // cloudflared takes the first match, on the decoded path; RE2 and JavaScript agree on these
  // patterns' syntax
  return buildTunnelIngresses(gateway).findIndex(
    (rule) =>
      (rule.hostname === undefined || rule.hostname === hostname) &&
      (rule.path === undefined || new RegExp(rule.path, 'u').test(path)),
  );
}

test.each([
  ['GET /oauth2/authorize', '/oauth2/authorize'],
  ['GET /login and POST /login', '/login'],
  ['GET /enroll and POST /enroll', '/enroll'],
  ['GET /consent and POST /consent', '/consent'],
  ['GET /error', '/error'],
])('it sends %s to the Access-checked rule', (_route: string, path: string) => {
  expect(findRuleIndex('atc.geoff.cloud', path)).toBe(0);
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
  expect(findRuleIndex('atc.geoff.cloud', path)).toBe(1);
});

test.each([
  ['a trailing slash', '/login/'],
  ['a trailing slash on the enrollment page', '/enroll/'],
  ['another case', '/LOGIN'],
  ['a longer name', '/login2'],
  ['a subpath of a machine route', '/mcp/login'],
  ['a doubled slash', '//login'],
  ['a dot segment', '/mcp/../login'],
  ['a backslash', String.raw`/mcp\..\login`],
  ['a matrix parameter', '/login;x'],
  ['the any-character dot of a pattern', '/Xwell-known/oauth-authorization-server'],
  ['the liveness probe', '/healthz'],
  ['the readiness probe', '/readyz'],
  ['the preview webhook path', '/webhook'],
  ['a path atc does not serve', '/api/auth/sign-in'],
])(
  'it answers %s on the gateway hostname with the 404 catch-all',
  (_variant: string, path: string) => {
    expect(findRuleIndex('atc.geoff.cloud', path)).toBe(2);
  },
);

test.each(['/login', '/enroll', '/consent', '/oauth2/authorize'])(
  'it answers the browser path %s on the preview webhook hostname with the 404 catch-all',
  (path: string) => {
    expect(findRuleIndex('preview-webhook.geoff.cloud', path)).toBe(2);
  },
);

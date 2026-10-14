import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildMockTunnelRoute } from '../test-utils/build-mock-tunnel-route.ts';
import type { GatewayIngress, OriginAccess } from './build-tunnel-ingresses.ts';
import { buildTunnelIngresses } from './build-tunnel-ingresses.ts';

const browserPattern = '^(?:/oauth2/authorize|/login|/consent|/error)$';
const machinePattern = String.raw`^(?:/|/mcp|/oauth2/token|/oauth2/revoke|/\.well-known/oauth-authorization-server|/\.well-known/oauth-protected-resource|/\.well-known/oauth-protected-resource/mcp)$`;

function buildGateway(access: OriginAccess): GatewayIngress {
  return { route: buildMockTunnelRoute({ hostname: 'atc.geoff.cloud' }), access };
}

test("it sends the gateway's browser paths through cloudflared's Access check and its machine paths straight through, with the 404 catch-all last", () => {
  const service = output('http://atc-gateway.atc.svc.cluster.local:8414');
  const teamName = output('geoff');
  const audience = output('0123456789abcdef');

  expect(
    buildTunnelIngresses({
      route: buildMockTunnelRoute({ hostname: 'atc.geoff.cloud', service }),
      access: { teamName, audience },
    }),
  ).toStrictEqual([
    {
      hostname: 'atc.geoff.cloud',
      path: browserPattern,
      service,
      originRequest: { access: { required: true, teamName, audTags: [audience] } },
    },
    { hostname: 'atc.geoff.cloud', path: machinePattern, service },
    { service: 'http_status:404' },
  ]);
});

// cloudflared's first-match rule: the hostname equals the rule's, and the rule's path pattern
// matches the request's decoded path. RE2 and JavaScript agree on these patterns' syntax.
function findRuleIndex(gateway: GatewayIngress, hostname: string, path: string): number {
  return buildTunnelIngresses(gateway).findIndex(
    (rule) =>
      (rule.hostname === undefined || rule.hostname === hostname) &&
      (rule.path === undefined || new RegExp(rule.path, 'u').test(path)),
  );
}

const access = { teamName: output('geoff'), audience: output('0123456789abcdef') };

test.each([
  ['GET /oauth2/authorize', '/oauth2/authorize'],
  ['GET /login and POST /login', '/login'],
  ['GET /consent and POST /consent', '/consent'],
  ['GET /error', '/error'],
])('it sends %s to the Access-checked rule', (_route: string, path: string) => {
  expect(findRuleIndex(buildGateway(access), 'atc.geoff.cloud', path)).toBe(0);
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
  expect(findRuleIndex(buildGateway(access), 'atc.geoff.cloud', path)).toBe(1);
});

test.each([
  ['a trailing slash', '/login/'],
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
  ['a path atc does not serve', '/api/auth/sign-in'],
])('it answers %s with the 404 catch-all', (_variant: string, path: string) => {
  expect(findRuleIndex(buildGateway(access), 'atc.geoff.cloud', path)).toBe(2);
});

test('it answers a browser path on another hostname that reaches the tunnel with the 404 catch-all', () => {
  expect(findRuleIndex(buildGateway(access), 'imp.geoff.cloud', '/login')).toBe(2);
});

test('it refuses a hostname that the exposure registry reserves', () => {
  expect(() =>
    buildTunnelIngresses({
      route: buildMockTunnelRoute({ hostname: 'imp.geoff.cloud' }),
      access,
    }),
  ).toThrowWithMessage(
    Error,
    'tunnel hostname imp.geoff.cloud is reserved in packages/topology/exposure.json; a route needs a public tunnel-hostname entry',
  );
});

test('it refuses a hostname that the exposure registry does not list', () => {
  expect(() =>
    buildTunnelIngresses({
      route: buildMockTunnelRoute({ hostname: 'grafana.geoff.cloud' }),
      access,
    }),
  ).toThrowWithMessage(
    Error,
    'tunnel hostname grafana.geoff.cloud is not in packages/topology/exposure.json; a route needs a public tunnel-hostname entry',
  );
});

test('it holds only the 404 catch-all without a route', () => {
  expect(buildTunnelIngresses(undefined)).toStrictEqual([{ service: 'http_status:404' }]);
});

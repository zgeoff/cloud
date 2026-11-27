import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import invariant from 'tiny-invariant';
import { atcGatewayPaths, atcGatewayRPCPathPattern } from './atc-gateway-paths.ts';
import { buildATCTunnelIngresses } from './build-atc-tunnel-ingresses.ts';
import { buildSignInRoutes } from './build-sign-in-routes.ts';
import { buildTunnelIngresses } from './build-tunnel-ingresses.ts';

test("it sends the gateway's browser paths through the Access check, and its machine and /rpc paths without one, to the pod's loopback, then answers 404", () => {
  const teamName = output('example-team');
  const audience = output('0123456789abcdef');

  expect(buildATCTunnelIngresses('atc.geoff.cloud', { teamName, audience })).toStrictEqual([
    {
      hostname: 'atc.geoff.cloud',
      path: '^(?:/oauth2/authorize|/login|/enroll|/consent|/error)$',
      service: 'http://127.0.0.1:8414',
      originRequest: { access: { required: true, teamName, audTags: [audience] } },
    },
    {
      hostname: 'atc.geoff.cloud',
      path: String.raw`^(?:/|/mcp|/oauth2/token|/oauth2/revoke|/\.well-known/oauth-authorization-server|/\.well-known/oauth-protected-resource|/\.well-known/oauth-protected-resource/mcp)$`,
      service: 'http://127.0.0.1:8414',
    },
    {
      hostname: 'atc.geoff.cloud',
      path: '^/rpc(?:/[A-Za-z0-9_-]+)+$',
      service: 'http://127.0.0.1:8414',
    },
    { service: 'http_status:404' },
  ]);
});

test('it routes each fleet procedure path under /rpc, and no bare /rpc or dot segment', () => {
  const pattern = new RegExp(atcGatewayRPCPathPattern, 'u');

  expect(
    ['/rpc/session/list', '/rpc/events/stream', '/rpc', '/rpc/', '/rpc/../mcp', '/x/rpc/a'].map(
      (path) => [path, pattern.test(path)],
    ),
  ).toStrictEqual([
    ['/rpc/session/list', true],
    ['/rpc/events/stream', true],
    ['/rpc', false],
    ['/rpc/', false],
    ['/rpc/../mcp', false],
    ['/x/rpc/a', false],
  ]);
});

test("it renders the gateway's sign-in route rules unchanged but for the origin, the pod's loopback", () => {
  const access = { teamName: output('example-team'), audience: output('0123456789abcdef') };

  const shared = buildTunnelIngresses(
    buildSignInRoutes(
      { hostname: 'atc.geoff.cloud', service: 'http://atc-gateway.atc.svc.cluster.local:8414' },
      atcGatewayPaths,
      access,
    ),
  );

  const [browser, machine, catchAll] = shared;

  invariant(browser && machine && catchAll && shared.length === 3);

  expect(buildATCTunnelIngresses('atc.geoff.cloud', access)).toStrictEqual([
    { ...browser, service: 'http://127.0.0.1:8414' },
    { ...machine, service: 'http://127.0.0.1:8414' },
    expect.objectContaining({ path: atcGatewayRPCPathPattern }),
    catchAll,
  ]);
});

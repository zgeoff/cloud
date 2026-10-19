import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import invariant from 'tiny-invariant';
import { buildATCGatewayRoutes } from './build-atc-gateway-routes.ts';
import { buildATCTunnelIngresses } from './build-atc-tunnel-ingresses.ts';
import { buildTunnelIngresses } from './build-tunnel-ingresses.ts';

test("it sends the gateway's browser paths through the Access check and its machine paths without one to the pod's loopback, then answers 404", () => {
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
    { service: 'http_status:404' },
  ]);
});

test("it renders the gateway's route rules unchanged but for the origin, the pod's loopback", () => {
  const access = { teamName: output('example-team'), audience: output('0123456789abcdef') };

  const shared = buildTunnelIngresses(
    buildATCGatewayRoutes(
      { hostname: 'atc.geoff.cloud', service: 'http://atc-gateway.atc.svc.cluster.local:8414' },
      access,
    ),
  );

  const [browser, machine, catchAll] = shared;

  invariant(browser && machine && catchAll && shared.length === 3);

  expect(buildATCTunnelIngresses('atc.geoff.cloud', access)).toStrictEqual([
    { ...browser, service: 'http://127.0.0.1:8414' },
    { ...machine, service: 'http://127.0.0.1:8414' },
    catchAll,
  ]);
});

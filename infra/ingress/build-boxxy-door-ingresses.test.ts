import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildBoxxyDoorIngresses } from './build-boxxy-door-ingresses.ts';

test("it sends the door's browser paths through the Access check and its machine paths without one to the pod's loopback, then answers 404", () => {
  const teamName = output('example-team');
  const audience = output('0123456789abcdef');

  expect(buildBoxxyDoorIngresses('boxxy.geoff.cloud', { teamName, audience })).toStrictEqual([
    {
      hostname: 'boxxy.geoff.cloud',
      path: '^(?:/oauth2/authorize|/login|/enroll|/consent|/error)$',
      service: 'http://127.0.0.1:8092',
      originRequest: { access: { required: true, teamName, audTags: [audience] } },
    },
    {
      hostname: 'boxxy.geoff.cloud',
      path: String.raw`^(?:/mcp|/oauth2/token|/oauth2/revoke|/\.well-known/oauth-authorization-server|/\.well-known/oauth-protected-resource|/\.well-known/oauth-protected-resource/mcp)$`,
      service: 'http://127.0.0.1:8092',
    },
    { service: 'http_status:404' },
  ]);
});

test.each(['/oauth2/authorize', '/login', '/enroll', '/consent', '/error'])(
  'it sends the browser path %s to the Access-checked rule',
  (path: string) => {
    const rules = buildBoxxyDoorIngresses('boxxy.geoff.cloud', {
      teamName: output('example-team'),
      audience: output('0123456789abcdef'),
    });

    // cloudflared takes the first match, on the decoded path; RE2 and JavaScript agree on these
    // patterns' syntax
    expect(
      rules.findIndex(
        (rule) =>
          (rule.hostname === undefined || rule.hostname === 'boxxy.geoff.cloud') &&
          (rule.path === undefined || new RegExp(rule.path, 'u').test(path)),
      ),
    ).toBe(0);
  },
);

test.each([
  '/mcp',
  '/oauth2/token',
  '/oauth2/revoke',
  '/.well-known/oauth-authorization-server',
  '/.well-known/oauth-protected-resource',
  '/.well-known/oauth-protected-resource/mcp',
])('it sends the machine path %s to the rule without an Access check', (path: string) => {
  const rules = buildBoxxyDoorIngresses('boxxy.geoff.cloud', {
    teamName: output('example-team'),
    audience: output('0123456789abcdef'),
  });

  expect(
    rules.findIndex(
      (rule) =>
        (rule.hostname === undefined || rule.hostname === 'boxxy.geoff.cloud') &&
        (rule.path === undefined || new RegExp(rule.path, 'u').test(path)),
    ),
  ).toBe(1);
});

test.each([
  ['the owner RPC route', '/rpc'],
  ["an owner RPC procedure's path", '/rpc/auth/clients/add'],
  ['the health check', '/healthz'],
  ['the root, which the door gives no MCP alias', '/'],
  ["the worker's MCP route", '/mcp/session'],
  ['a trailing slash', '/login/'],
  ['another case', '/MCP'],
  ['a dot segment', '/mcp/../rpc'],
])('it answers %s with the 404 catch-all', (_variant: string, path: string) => {
  const rules = buildBoxxyDoorIngresses('boxxy.geoff.cloud', {
    teamName: output('example-team'),
    audience: output('0123456789abcdef'),
  });

  expect(
    rules.findIndex(
      (rule) =>
        (rule.hostname === undefined || rule.hostname === 'boxxy.geoff.cloud') &&
        (rule.path === undefined || new RegExp(rule.path, 'u').test(path)),
    ),
  ).toBe(2);
});

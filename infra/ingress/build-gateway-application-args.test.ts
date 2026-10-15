import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildGatewayApplicationArgs } from './build-gateway-application-args.ts';

const destinations = [
  { type: 'public', uri: 'atc.geoff.cloud/oauth2/authorize' },
  { type: 'public', uri: 'atc.geoff.cloud/login' },
  { type: 'public', uri: 'atc.geoff.cloud/enroll' },
  { type: 'public', uri: 'atc.geoff.cloud/consent' },
  { type: 'public', uri: 'atc.geoff.cloud/error' },
];

test("it fronts only the gateway's browser paths, with the one-time PIN and the owner policy alone", () => {
  const identityProviderID = output('one-time-pin-id');
  const policyID = output('owner-policy-id');

  expect(
    buildGatewayApplicationArgs({
      accountID: 'account-id',
      hostname: 'atc.geoff.cloud',
      identityProviderID,
      policyID,
    }),
  ).toStrictEqual({
    accountId: 'account-id',
    name: 'atc gateway sign-in',
    type: 'self_hosted',
    domain: 'atc.geoff.cloud/oauth2/authorize',
    destinations,
    policies: [{ id: policyID, precedence: 1 }],
    allowedIdps: [identityProviderID],
    autoRedirectToIdentity: true,
    appLauncherVisible: false,
    sessionDuration: '1h',
    httpOnlyCookieAttribute: true,
    sameSiteCookieAttribute: 'lax',
  });
});

// Access covers a destination's path and every path under it
test.each([
  '/',
  '/mcp',
  '/oauth2/token',
  '/oauth2/revoke',
  '/.well-known/oauth-authorization-server',
  '/.well-known/oauth-protected-resource',
  '/.well-known/oauth-protected-resource/mcp',
])('it leaves the machine path %s outside every destination', (path: string) => {
  const url = `atc.geoff.cloud${path}`;

  expect(
    destinations.filter(
      (destination) => url === destination.uri || url.startsWith(`${destination.uri}/`),
    ),
  ).toStrictEqual([]);
});

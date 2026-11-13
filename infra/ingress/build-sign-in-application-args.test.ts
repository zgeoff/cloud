import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { atcGatewayPaths } from './atc-gateway-paths.ts';
import { boxxyDoorPaths } from './boxxy-door-paths.ts';
import { buildSignInApplicationArgs } from './build-sign-in-application-args.ts';
import { pepysAPIPaths } from './pepys-api-paths.ts';

test("it fronts only the gateway's browser paths, with the one-time PIN and the owner policy alone", () => {
  const identityProviderID = output('one-time-pin-id');
  const policyID = output('owner-policy-id');

  expect(
    buildSignInApplicationArgs({
      accountID: 'account-id',
      name: 'atc gateway sign-in',
      hostname: 'atc.geoff.cloud',
      browserPaths: atcGatewayPaths.browser,
      identityProviderID,
      policyID,
    }),
  ).toStrictEqual({
    accountId: 'account-id',
    name: 'atc gateway sign-in',
    type: 'self_hosted',
    domain: 'atc.geoff.cloud/oauth2/authorize',
    destinations: [
      { type: 'public', uri: 'atc.geoff.cloud/oauth2/authorize' },
      { type: 'public', uri: 'atc.geoff.cloud/login' },
      { type: 'public', uri: 'atc.geoff.cloud/enroll' },
      { type: 'public', uri: 'atc.geoff.cloud/consent' },
      { type: 'public', uri: 'atc.geoff.cloud/error' },
    ],
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

  const destinations = [
    { type: 'public', uri: 'atc.geoff.cloud/oauth2/authorize' },
    { type: 'public', uri: 'atc.geoff.cloud/login' },
    { type: 'public', uri: 'atc.geoff.cloud/enroll' },
    { type: 'public', uri: 'atc.geoff.cloud/consent' },
    { type: 'public', uri: 'atc.geoff.cloud/error' },
  ];

  expect(
    destinations.filter(
      (destination) => url === destination.uri || url.startsWith(`${destination.uri}/`),
    ),
  ).toStrictEqual([]);
});

test("it fronts only the pepys API's browser paths, with the one-time PIN and the owner policy alone", () => {
  const identityProviderID = output('one-time-pin-id');
  const policyID = output('owner-policy-id');

  expect(
    buildSignInApplicationArgs({
      accountID: 'account-id',
      name: 'pepys API sign-in',
      hostname: 'pepys.geoff.cloud',
      browserPaths: pepysAPIPaths.browser,
      identityProviderID,
      policyID,
    }),
  ).toStrictEqual({
    accountId: 'account-id',
    name: 'pepys API sign-in',
    type: 'self_hosted',
    domain: 'pepys.geoff.cloud/oauth2/authorize',
    destinations: [
      { type: 'public', uri: 'pepys.geoff.cloud/oauth2/authorize' },
      { type: 'public', uri: 'pepys.geoff.cloud/login' },
      { type: 'public', uri: 'pepys.geoff.cloud/enroll' },
      { type: 'public', uri: 'pepys.geoff.cloud/consent' },
      { type: 'public', uri: 'pepys.geoff.cloud/error' },
    ],
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
])("it leaves the pepys API's machine path %s outside every destination", (path: string) => {
  const url = `pepys.geoff.cloud${path}`;

  const destinations = [
    { type: 'public', uri: 'pepys.geoff.cloud/oauth2/authorize' },
    { type: 'public', uri: 'pepys.geoff.cloud/login' },
    { type: 'public', uri: 'pepys.geoff.cloud/enroll' },
    { type: 'public', uri: 'pepys.geoff.cloud/consent' },
    { type: 'public', uri: 'pepys.geoff.cloud/error' },
  ];

  expect(
    destinations.filter(
      (destination) => url === destination.uri || url.startsWith(`${destination.uri}/`),
    ),
  ).toStrictEqual([]);
});

test("it fronts the boxxy door's browser paths alone", () => {
  expect(
    buildSignInApplicationArgs({
      accountID: 'account-id',
      name: 'boxxy door sign-in',
      hostname: 'boxxy.geoff.cloud',
      browserPaths: boxxyDoorPaths.browser,
      identityProviderID: output('one-time-pin-id'),
      policyID: output('owner-policy-id'),
    }).destinations,
  ).toStrictEqual([
    { type: 'public', uri: 'boxxy.geoff.cloud/oauth2/authorize' },
    { type: 'public', uri: 'boxxy.geoff.cloud/login' },
    { type: 'public', uri: 'boxxy.geoff.cloud/enroll' },
    { type: 'public', uri: 'boxxy.geoff.cloud/consent' },
    { type: 'public', uri: 'boxxy.geoff.cloud/error' },
  ]);
});

// Access covers a destination's path and every path under it
test.each(boxxyDoorPaths.machine)(
  "it leaves the boxxy door's machine path %s outside every destination",
  (path: string) => {
    const url = `boxxy.geoff.cloud${path}`;

    const destinations = [
      { type: 'public', uri: 'boxxy.geoff.cloud/oauth2/authorize' },
      { type: 'public', uri: 'boxxy.geoff.cloud/login' },
      { type: 'public', uri: 'boxxy.geoff.cloud/enroll' },
      { type: 'public', uri: 'boxxy.geoff.cloud/consent' },
      { type: 'public', uri: 'boxxy.geoff.cloud/error' },
    ];

    expect(
      destinations.filter(
        (destination) => url === destination.uri || url.startsWith(`${destination.uri}/`),
      ),
    ).toStrictEqual([]);
  },
);

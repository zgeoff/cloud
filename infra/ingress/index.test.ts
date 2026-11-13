import { expect, onTestFinished, test } from 'bun:test';
import { output, runtime } from '@pulumi/pulumi';
import { buildStubResourceMocks } from '../test-utils/build-stub-resource-mocks.ts';
import { resolveOutput } from '../test-utils/resolve-output.ts';
import { createIngress } from './index.ts';

test("it puts the files service's route on the shared tunnel and points a proxied CNAME at it", async () => {
  const stub = buildStubResourceMocks();

  await runtime.setMocks(stub.mocks, 'geoff-cloud', 'test');

  onTestFinished(() => {
    stub.release();
    runtime.resetOptions('', '', -1, '', '', false, '');
  });

  const ingress = createIngress({
    accountID: 'account',
    zoneID: output('zone'),
    cluster: undefined,
    atcRoute: undefined,
    ownerEmail: undefined,
    pepysAPIRoute: undefined,
    atcTunnel: undefined,
    filesRoute: {
      hostname: 'files.geoff.cloud',
      service: output('http://files.files.svc.cluster.local:8080'),
    },
    pepysRoute: undefined,
  });

  if (ingress.filesURL === undefined) {
    throw new Error('the ingress returned no files URL');
  }

  const filesURL = await resolveOutput(ingress.filesURL);

  await resolveOutput(ingress.tunnelConfigVersion);

  expect(
    stub.inputs.get(
      'cloudflare:index/zeroTrustTunnelCloudflaredConfig:ZeroTrustTunnelCloudflaredConfig::edge',
    ),
  ).toStrictEqual({
    accountId: 'account',
    tunnelId: 'edge-id',
    config: {
      ingresses: [
        {
          hostname: 'preview-webhook.geoff.cloud',
          path: '^/webhook$',
          service: 'http://100.69.47.33:8418',
        },
        { hostname: 'files.geoff.cloud', service: 'http://files.files.svc.cluster.local:8080' },
        { service: 'http_status:404' },
      ],
    },
  });

  expect(stub.inputs.get('cloudflare:index/dnsRecord:DnsRecord::files')).toStrictEqual({
    zoneId: 'zone',
    name: 'files.geoff.cloud',
    type: 'CNAME',
    content: 'edge-id.cfargotunnel.com',
    proxied: true,
    ttl: 1,
  });

  expect(filesURL).toBe('https://files.geoff.cloud');
});

test('it adds no files rule, record or URL without the files route', async () => {
  const stub = buildStubResourceMocks();

  await runtime.setMocks(stub.mocks, 'geoff-cloud', 'test');

  onTestFinished(() => {
    stub.release();
    runtime.resetOptions('', '', -1, '', '', false, '');
  });

  const ingress = createIngress({
    accountID: 'account',
    zoneID: output('zone'),
    cluster: undefined,
    atcRoute: undefined,
    ownerEmail: undefined,
    pepysAPIRoute: undefined,
    atcTunnel: undefined,
    filesRoute: undefined,
    pepysRoute: undefined,
  });

  await resolveOutput(ingress.tunnelConfigVersion);

  expect(ingress.filesURL).toBeUndefined();

  expect(
    stub.inputs.get(
      'cloudflare:index/zeroTrustTunnelCloudflaredConfig:ZeroTrustTunnelCloudflaredConfig::edge',
    ),
  ).toStrictEqual({
    accountId: 'account',
    tunnelId: 'edge-id',
    config: {
      ingresses: [
        {
          hostname: 'preview-webhook.geoff.cloud',
          path: '^/webhook$',
          service: 'http://100.69.47.33:8418',
        },
        { service: 'http_status:404' },
      ],
    },
  });

  expect(stub.registered).not.toContain('cloudflare:index/dnsRecord:DnsRecord::files');
  expect(stub.registered).not.toContain('cloudflare:index/dnsRecord:DnsRecord::pepys-webhook');
});

test("it puts pepys's public paths on the shared tunnel and points a proxied CNAME at them", async () => {
  const stub = buildStubResourceMocks();

  await runtime.setMocks(stub.mocks, 'geoff-cloud', 'test');

  onTestFinished(() => {
    stub.release();
    runtime.resetOptions('', '', -1, '', '', false, '');
  });

  const ingress = createIngress({
    accountID: 'account',
    zoneID: output('zone'),
    cluster: undefined,
    atcRoute: undefined,
    ownerEmail: undefined,
    pepysAPIRoute: undefined,
    atcTunnel: undefined,
    filesRoute: undefined,
    pepysRoute: {
      hostname: 'pepys-webhook.geoff.cloud',
      service: 'http://pepys-ingest.pepys.svc.cluster.local:8080',
      path: '^(?:/webhook/github)$',
    },
  });

  if (ingress.pepysWebhookURL === undefined) {
    throw new Error('the ingress returned no pepys URL');
  }

  const pepysURL = await resolveOutput(ingress.pepysWebhookURL);

  await resolveOutput(ingress.tunnelConfigVersion);

  expect(
    stub.inputs.get(
      'cloudflare:index/zeroTrustTunnelCloudflaredConfig:ZeroTrustTunnelCloudflaredConfig::edge',
    ),
  ).toStrictEqual({
    accountId: 'account',
    tunnelId: 'edge-id',
    config: {
      ingresses: [
        {
          hostname: 'preview-webhook.geoff.cloud',
          path: '^/webhook$',
          service: 'http://100.69.47.33:8418',
        },
        {
          hostname: 'pepys-webhook.geoff.cloud',
          path: '^(?:/webhook/github)$',
          service: 'http://pepys-ingest.pepys.svc.cluster.local:8080',
        },
        { service: 'http_status:404' },
      ],
    },
  });

  expect(stub.inputs.get('cloudflare:index/dnsRecord:DnsRecord::pepys-webhook')).toStrictEqual({
    zoneId: 'zone',
    name: 'pepys-webhook.geoff.cloud',
    type: 'CNAME',
    content: 'edge-id.cfargotunnel.com',
    proxied: true,
    ttl: 1,
  });

  expect(pepysURL).toBe('https://pepys-webhook.geoff.cloud');
});

test("it puts the pepys API's paths on the shared tunnel, fronts its browser paths with an owner-only Access application, and points a proxied CNAME at it", async () => {
  const stub = buildStubResourceMocks([], {
    'cloudflare:index/zeroTrustAccessApplication:ZeroTrustAccessApplication::pepys-api-sign-in': {
      aud: 'pepys-api-audience',
    },
  });

  await runtime.setMocks(
    { ...stub.mocks, call: () => ({ authDomain: 'example-team.cloudflareaccess.com' }) },
    'geoff-cloud',
    'test',
  );

  onTestFinished(() => {
    stub.release();
    runtime.resetOptions('', '', -1, '', '', false, '');
  });

  const ingress = createIngress({
    accountID: 'account',
    zoneID: output('zone'),
    cluster: undefined,
    atcRoute: undefined,
    ownerEmail: output('owner@example.test'),
    atcTunnel: undefined,
    filesRoute: undefined,
    pepysRoute: undefined,
    pepysAPIRoute: {
      hostname: 'pepys.geoff.cloud',
      service: 'http://pepys-host.pepys.svc.cluster.local:8081',
    },
  });

  if (ingress.pepysAPIURL === undefined) {
    throw new Error('the ingress returned no pepys API URL');
  }

  const pepysAPIURL = await resolveOutput(ingress.pepysAPIURL);

  await resolveOutput(ingress.tunnelConfigVersion);

  expect(
    stub.inputs.get(
      'cloudflare:index/zeroTrustTunnelCloudflaredConfig:ZeroTrustTunnelCloudflaredConfig::edge',
    ),
  ).toStrictEqual({
    accountId: 'account',
    tunnelId: 'edge-id',
    config: {
      ingresses: [
        {
          hostname: 'preview-webhook.geoff.cloud',
          path: '^/webhook$',
          service: 'http://100.69.47.33:8418',
        },
        {
          hostname: 'pepys.geoff.cloud',
          path: '^(?:/oauth2/authorize|/login|/enroll|/consent|/error)$',
          service: 'http://pepys-host.pepys.svc.cluster.local:8081',
          originRequest: {
            access: {
              required: true,
              teamName: 'example-team',
              audTags: ['pepys-api-audience'],
            },
          },
        },
        {
          hostname: 'pepys.geoff.cloud',
          path: String.raw`^(?:/|/mcp|/oauth2/token|/oauth2/revoke|/\.well-known/oauth-authorization-server|/\.well-known/oauth-protected-resource|/\.well-known/oauth-protected-resource/mcp)$`,
          service: 'http://pepys-host.pepys.svc.cluster.local:8081',
        },
        { service: 'http_status:404' },
      ],
    },
  });

  expect(
    stub.inputs.get(
      'cloudflare:index/zeroTrustAccessApplication:ZeroTrustAccessApplication::pepys-api-sign-in',
    ),
  ).toStrictEqual({
    accountId: 'account',
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
    policies: [{ id: 'pepys-api-owner-id', precedence: 1 }],
    allowedIdps: ['one-time-pin-id'],
    autoRedirectToIdentity: true,
    appLauncherVisible: false,
    sessionDuration: '1h',
    httpOnlyCookieAttribute: true,
    sameSiteCookieAttribute: 'lax',
  });

  expect(
    stub.inputs.get(
      'cloudflare:index/zeroTrustAccessPolicy:ZeroTrustAccessPolicy::pepys-api-owner',
    ),
  ).toStrictEqual({
    accountId: 'account',
    name: 'pepys API owner',
    decision: 'allow',
    includes: [{ email: { email: 'owner@example.test' } }],
    requires: [{ loginMethod: { id: 'one-time-pin-id' } }],
  });

  expect(stub.inputs.get('cloudflare:index/dnsRecord:DnsRecord::pepys-api')).toStrictEqual({
    zoneId: 'zone',
    name: 'pepys.geoff.cloud',
    type: 'CNAME',
    content: 'edge-id.cfargotunnel.com',
    proxied: true,
    ttl: 1,
  });

  expect(pepysAPIURL).toBe('https://pepys.geoff.cloud');
});

test('it gives the atc gateway and the pepys API one one-time PIN login between them', async () => {
  const stub = buildStubResourceMocks();

  await runtime.setMocks(
    { ...stub.mocks, call: () => ({ authDomain: 'example-team.cloudflareaccess.com' }) },
    'geoff-cloud',
    'test',
  );

  onTestFinished(() => {
    stub.release();
    runtime.resetOptions('', '', -1, '', '', false, '');
  });

  const ingress = createIngress({
    accountID: 'account',
    zoneID: output('zone'),
    cluster: undefined,
    atcRoute: { hostname: 'atc.geoff.cloud', service: 'http://127.0.0.1:8414' },
    ownerEmail: output('owner@example.test'),
    atcTunnel: { tunnelID: output('atc-id'), tunnelToken: output('atc-token-for-tests') },
    filesRoute: undefined,
    pepysRoute: undefined,
    pepysAPIRoute: {
      hostname: 'pepys.geoff.cloud',
      service: 'http://pepys-host.pepys.svc.cluster.local:8081',
    },
  });

  await resolveOutput(ingress.tunnelConfigVersion);

  expect(
    stub.registered.filter((key) =>
      key.startsWith('cloudflare:index/zeroTrustAccessIdentityProvider:'),
    ),
  ).toStrictEqual([
    'cloudflare:index/zeroTrustAccessIdentityProvider:ZeroTrustAccessIdentityProvider::one-time-pin',
  ]);
});

test("it refuses the pepys API's route without an owner address for its Access policy", () => {
  expect(() =>
    createIngress({
      accountID: 'account',
      zoneID: output('zone'),
      cluster: undefined,
      atcRoute: undefined,
      ownerEmail: undefined,
      atcTunnel: undefined,
      filesRoute: undefined,
      pepysRoute: undefined,
      pepysAPIRoute: {
        hostname: 'pepys.geoff.cloud',
        service: 'http://pepys-host.pepys.svc.cluster.local:8081',
      },
    }),
  ).toThrowWithMessage(
    Error,
    "the pepys API's route has no owner address for its Access policy; it takes the atc gateway's",
  );
});

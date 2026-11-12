import { expect, onTestFinished, test } from 'bun:test';
import { output, runtime } from '@pulumi/pulumi';
import invariant from 'tiny-invariant';
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
    atcOwnerEmail: undefined,
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
    atcOwnerEmail: undefined,
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
    atcOwnerEmail: undefined,
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

test("it fronts the gateway's and the boxxy door's sign-in pages with an owner-only application each, on the one one-time PIN login", async () => {
  const stub = buildStubResourceMocks();

  await runtime.setMocks(
    {
      ...stub.mocks,

      // the account's Zero Trust organization, which names the team that cloudflared checks
      // Access tokens against
      call: (args: runtime.MockCallArgs) =>
        args.token === 'cloudflare:index/getZeroTrustOrganization:getZeroTrustOrganization'
          ? { authDomain: 'example-team.cloudflareaccess.com' }
          : stub.mocks.call(args),
    },
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
    atcRoute: {
      hostname: 'atc.geoff.cloud',
      service: output('http://atc-gateway.atc.svc.cluster.local:8414'),
    },
    atcOwnerEmail: output('owner@example.test'),
    atcTunnel: { tunnelID: output('atc-tunnel'), tunnelToken: output('atc-tunnel-token') },
    boxxyDoorHostname: 'boxxy.geoff.cloud',
    boxxyTunnel: { tunnelID: output('boxxy-tunnel'), tunnelToken: output('boxxy-tunnel-token') },
    filesRoute: undefined,
    pepysRoute: undefined,
  });

  invariant(ingress.boxxyDoorConfigVersion);

  await resolveOutput(ingress.boxxyDoorConfigVersion);

  expect({
    identityProviders: stub.registered.filter((key) =>
      key.startsWith(
        'cloudflare:index/zeroTrustAccessIdentityProvider:ZeroTrustAccessIdentityProvider::',
      ),
    ),
    policy: stub.inputs.get(
      'cloudflare:index/zeroTrustAccessPolicy:ZeroTrustAccessPolicy::boxxy-door-owner',
    ),
    application: stub.inputs.get(
      'cloudflare:index/zeroTrustAccessApplication:ZeroTrustAccessApplication::boxxy-door-sign-in',
    ),
    gatewayApplication: stub.inputs.get(
      'cloudflare:index/zeroTrustAccessApplication:ZeroTrustAccessApplication::atc-gateway-sign-in',
    )?.['name'],
  }).toStrictEqual({
    identityProviders: [
      'cloudflare:index/zeroTrustAccessIdentityProvider:ZeroTrustAccessIdentityProvider::one-time-pin',
    ],
    policy: {
      accountId: 'account',
      name: 'boxxy door owner',
      decision: 'allow',
      includes: [{ email: { email: 'owner@example.test' } }],
      requires: [{ loginMethod: { id: 'one-time-pin-id' } }],
    },
    application: {
      accountId: 'account',
      name: 'boxxy door sign-in',
      type: 'self_hosted',
      domain: 'boxxy.geoff.cloud/oauth2/authorize',
      destinations: [
        { type: 'public', uri: 'boxxy.geoff.cloud/oauth2/authorize' },
        { type: 'public', uri: 'boxxy.geoff.cloud/login' },
        { type: 'public', uri: 'boxxy.geoff.cloud/enroll' },
        { type: 'public', uri: 'boxxy.geoff.cloud/consent' },
        { type: 'public', uri: 'boxxy.geoff.cloud/error' },
      ],
      policies: [{ id: 'boxxy-door-owner-id', precedence: 1 }],
      allowedIdps: ['one-time-pin-id'],
      autoRedirectToIdentity: true,
      appLauncherVisible: false,
      sessionDuration: '1h',
      httpOnlyCookieAttribute: true,
      sameSiteCookieAttribute: 'lax',
    },
    gatewayApplication: 'atc gateway sign-in',
  });
});

test("it refuses the boxxy door's route without the owner address", async () => {
  const stub = buildStubResourceMocks();

  await runtime.setMocks(stub.mocks, 'geoff-cloud', 'test');

  onTestFinished(() => {
    stub.release();
    runtime.resetOptions('', '', -1, '', '', false, '');
  });

  expect(() =>
    createIngress({
      accountID: 'account',
      zoneID: output('zone'),
      cluster: undefined,
      atcRoute: undefined,
      atcOwnerEmail: undefined,
      atcTunnel: undefined,
      boxxyDoorHostname: 'boxxy.geoff.cloud',
      boxxyTunnel: { tunnelID: output('boxxy-tunnel'), tunnelToken: output('boxxy-tunnel-token') },
      filesRoute: undefined,
      pepysRoute: undefined,
    }),
  ).toThrowWithMessage(Error, "the boxxy door's route has no owner address for its Access policy");
});

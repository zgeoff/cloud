import { expect, onTestFinished, test } from 'bun:test';
import { output, runtime } from '@pulumi/pulumi';
import { buildStubResourceMocks } from '../test-utils/build-stub-resource-mocks.ts';
import { resolveOutput } from '../test-utils/resolve-output.ts';
import { createTunnelRoutes } from './create-tunnel-routes.ts';

test("it renders the gateway's loopback rules on the atc tunnel and points its CNAME at the atc tunnel", async () => {
  const stub = buildStubResourceMocks();

  await runtime.setMocks(stub.mocks, 'geoff-cloud', 'test');

  onTestFinished(() => {
    stub.release();
    runtime.resetOptions('', '', -1, '', '', false, '');
  });

  const routes = createTunnelRoutes({
    accountID: 'account',
    zoneID: output('zone'),
    tunnelID: output('shared-tunnel'),
    gateway: {
      hostname: 'atc.geoff.cloud',
      access: { teamName: output('example-team'), audience: output('0123456789abcdef') },
      tunnelID: output('atc-tunnel'),
    },
  });

  await resolveOutput(routes.configVersion);

  expect(
    stub.inputs.get(
      'cloudflare:index/zeroTrustTunnelCloudflaredConfig:ZeroTrustTunnelCloudflaredConfig::atc',
    ),
  ).toStrictEqual({
    accountId: 'account',
    tunnelId: 'atc-tunnel',
    config: {
      ingresses: [
        {
          hostname: 'atc.geoff.cloud',
          path: '^(?:/oauth2/authorize|/login|/enroll|/consent|/error)$',
          service: 'http://127.0.0.1:8414',
          originRequest: {
            access: { required: true, teamName: 'example-team', audTags: ['0123456789abcdef'] },
          },
        },
        {
          hostname: 'atc.geoff.cloud',
          path: String.raw`^(?:/|/mcp|/oauth2/token|/oauth2/revoke|/\.well-known/oauth-authorization-server|/\.well-known/oauth-protected-resource|/\.well-known/oauth-protected-resource/mcp)$`,
          service: 'http://127.0.0.1:8414',
        },
        { service: 'http_status:404' },
      ],
    },
  });

  expect(stub.inputs.get('cloudflare:index/dnsRecord:DnsRecord::atc')).toStrictEqual({
    zoneId: 'zone',
    name: 'atc.geoff.cloud',
    type: 'CNAME',
    content: 'atc-tunnel.cfargotunnel.com',
    proxied: true,
    ttl: 1,
  });
});

test("it registers the shared tunnel's rules only after the gateway's CNAME", async () => {
  const stub = buildStubResourceMocks([]);

  await runtime.setMocks(stub.mocks, 'geoff-cloud', 'test');

  onTestFinished(() => {
    stub.release();
    runtime.resetOptions('', '', -1, '', '', false, '');
  });

  const routes = createTunnelRoutes({
    accountID: 'account',
    zoneID: output('zone'),
    tunnelID: output('shared-tunnel'),
    gateway: {
      hostname: 'atc.geoff.cloud',
      access: { teamName: output('example-team'), audience: output('0123456789abcdef') },
      tunnelID: output('atc-tunnel'),
    },
  });

  await resolveOutput(routes.configVersion);

  expect(stub.registered.indexOf('cloudflare:index/dnsRecord:DnsRecord::atc')).toBeLessThan(
    stub.registered.indexOf(
      'cloudflare:index/zeroTrustTunnelCloudflaredConfig:ZeroTrustTunnelCloudflaredConfig::edge',
    ),
  );
});

test("it holds the shared tunnel's rules while the gateway's CNAME is still registering", async () => {
  const stub = buildStubResourceMocks(['cloudflare:index/dnsRecord:DnsRecord::atc']);

  await runtime.setMocks(stub.mocks, 'geoff-cloud', 'test');

  onTestFinished(() => {
    stub.release();
    runtime.resetOptions('', '', -1, '', '', false, '');
  });

  createTunnelRoutes({
    accountID: 'account',
    zoneID: output('zone'),
    tunnelID: output('shared-tunnel'),
    gateway: {
      hostname: 'atc.geoff.cloud',
      access: { teamName: output('example-team'), audience: output('0123456789abcdef') },
      tunnelID: output('atc-tunnel'),
    },
  });

  // the preview webhook's CNAME follows the shared tunnel's rules in the program and waits on
  // nothing, so once it registers, those rules would have registered too without the dependency
  await stub.whenRegistered('cloudflare:index/dnsRecord:DnsRecord::preview-webhook');

  expect(stub.registered).toContain('cloudflare:index/dnsRecord:DnsRecord::atc');

  expect(stub.registered).not.toContain(
    'cloudflare:index/zeroTrustTunnelCloudflaredConfig:ZeroTrustTunnelCloudflaredConfig::edge',
  );
});

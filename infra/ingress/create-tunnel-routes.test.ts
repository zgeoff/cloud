import { expect, onTestFinished, test } from 'bun:test';
import { output, runtime } from '@pulumi/pulumi';
import { buildStubResourceMocks } from '../test-utils/build-stub-resource-mocks.ts';
import { resolveOutput } from '../test-utils/resolve-output.ts';
import { createTunnelRoutes } from './create-tunnel-routes.ts';

test("it renders the gateway's loopback rules on the atc tunnel and keeps its CNAME on the shared tunnel", async () => {
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
      route: {
        hostname: 'atc.geoff.cloud',
        service: 'http://atc-gateway.atc.svc.cluster.local:8414',
      },
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
    content: 'shared-tunnel.cfargotunnel.com',
    proxied: true,
    ttl: 1,
  });
});

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
    atcOwnerEmail: undefined,
    atcTunnel: undefined,
    filesRoute: {
      hostname: 'files.geoff.cloud',
      service: output('http://files.files.svc.cluster.local:8080'),
    },
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
});

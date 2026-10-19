import { expect, test } from 'bun:test';
import { buildStubResourceMocks } from './build-stub-resource-mocks.ts';

test('it records each registration by type and name and returns its inputs as its state', async () => {
  const stub = buildStubResourceMocks();

  const result = await stub.mocks.newResource({
    type: 'cloudflare:index/dnsRecord:DnsRecord',
    name: 'atc',
    inputs: { name: 'atc.geoff.cloud' },
    custom: true,
  });

  expect(result).toStrictEqual({ id: 'atc-id', state: { name: 'atc.geoff.cloud' } });
  expect(stub.registered).toStrictEqual(['cloudflare:index/dnsRecord:DnsRecord::atc']);

  expect(stub.inputs).toStrictEqual(
    new Map([['cloudflare:index/dnsRecord:DnsRecord::atc', { name: 'atc.geoff.cloud' }]]),
  );
});

test('it keeps a held registration pending until release, after it has started', async () => {
  const stub = buildStubResourceMocks(['cloudflare:index/dnsRecord:DnsRecord::atc']);

  const pending = Promise.resolve(
    stub.mocks.newResource({
      type: 'cloudflare:index/dnsRecord:DnsRecord',
      name: 'atc',
      inputs: {},
      custom: true,
    }),
  );

  await stub.whenRegistered('cloudflare:index/dnsRecord:DnsRecord::atc');

  const beforeRelease = await Promise.race([
    pending.then(() => 'settled'),
    Promise.resolve('held'),
  ]);

  stub.release();

  expect(beforeRelease).toBe('held');
  expect(pending).resolves.toStrictEqual({ id: 'atc-id', state: {} });
});

test('it resolves whenRegistered for a registration that started before the wait', async () => {
  const stub = buildStubResourceMocks();

  await stub.mocks.newResource({
    type: 'cloudflare:index/dnsRecord:DnsRecord',
    name: 'preview-webhook',
    inputs: {},
    custom: true,
  });

  expect(
    stub.whenRegistered('cloudflare:index/dnsRecord:DnsRecord::preview-webhook'),
  ).resolves.toBeUndefined();
});

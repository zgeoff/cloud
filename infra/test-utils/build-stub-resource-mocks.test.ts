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

  let settled = false;

  const observed = (async () => {
    const value = await pending;

    settled = true;

    return value;
  })();

  await stub.whenRegistered('cloudflare:index/dnsRecord:DnsRecord::atc');

  // setImmediate runs only after every pending promise callback has run
  const flushed = Promise.withResolvers<void>();

  setImmediate(() => {
    flushed.resolve();
  });

  await flushed.promise;

  const settledBeforeRelease = settled;

  stub.release();

  const result = await observed;

  expect(settledBeforeRelease).toBeFalse();
  expect(result).toStrictEqual({ id: 'atc-id', state: {} });
  expect(settled).toBeTrue();
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

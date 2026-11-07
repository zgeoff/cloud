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

test("it adds a registration's given outputs to the state it returns, and records only its inputs", async () => {
  const stub = buildStubResourceMocks([], {
    'acme:index/certificate:Certificate::chat': { certificatePem: 'leaf-pem' },
  });

  const result = await stub.mocks.newResource({
    type: 'acme:index/certificate:Certificate',
    name: 'chat',
    inputs: { commonName: 'chat.example.test' },
    custom: true,
  });

  expect(result).toStrictEqual({
    id: 'chat-id',
    state: { commonName: 'chat.example.test', certificatePem: 'leaf-pem' },
  });

  expect(stub.inputs).toStrictEqual(
    new Map([['acme:index/certificate:Certificate::chat', { commonName: 'chat.example.test' }]]),
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

test('it keeps the other held registrations pending after a release of one key', async () => {
  const stub = buildStubResourceMocks([
    'cloudflare:index/dnsRecord:DnsRecord::atc',
    'cloudflare:index/dnsRecord:DnsRecord::files',
  ]);

  const atc = Promise.resolve(
    stub.mocks.newResource({
      type: 'cloudflare:index/dnsRecord:DnsRecord',
      name: 'atc',
      inputs: {},
      custom: true,
    }),
  );

  const files = Promise.resolve(
    stub.mocks.newResource({
      type: 'cloudflare:index/dnsRecord:DnsRecord',
      name: 'files',
      inputs: {},
      custom: true,
    }),
  );

  stub.releaseKey('cloudflare:index/dnsRecord:DnsRecord::atc');

  await atc;

  const filesStatus = Bun.peek.status(files);

  stub.release();

  await files;

  expect(filesStatus).toBe('pending');
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

import { expect, test } from 'bun:test';
import { buildStubR2Bucket } from '../../infra/test-utils/build-stub-r2-bucket.ts';
import { startStubHTTPServer } from '../../infra/test-utils/start-stub-http-server.ts';
import handler from './index.ts';

test.each([
  [530, 'tunnel-down'],
  [502, 'origin-down'],
  [504, 'origin-down'],
  [200, 'up'],
  [301, 'up'],
  [401, 'up'],
  [404, 'up'],
])('it records a target that answers %d as %s', async (status, health) => {
  await using target = startStubHTTPServer(status);

  const bucket = buildStubR2Bucket();

  await handler.scheduled(undefined, {
    STATE: bucket,
    TARGETS: JSON.stringify([{ name: 'atc', url: target.url }]),
  });

  expect(Object.fromEntries(bucket.objects)).toStrictEqual({ 'state:atc': health });
});

test('it records a target where nothing listens as unreachable', async () => {
  const closed = startStubHTTPServer(200);
  const url = closed.url;

  await closed[Symbol.asyncDispose]();

  const bucket = buildStubR2Bucket();

  await handler.scheduled(undefined, {
    STATE: bucket,
    TARGETS: JSON.stringify([{ name: 'atc', url }]),
  });

  expect(Object.fromEntries(bucket.objects)).toStrictEqual({ 'state:atc': 'unreachable' });
});

test('it records each target under its own name', async () => {
  await using atc = startStubHTTPServer(200);
  await using imp = startStubHTTPServer(502);

  const bucket = buildStubR2Bucket();

  await handler.scheduled(undefined, {
    STATE: bucket,
    TARGETS: JSON.stringify([
      { name: 'atc', url: atc.url },
      { name: 'imp', url: imp.url },
    ]),
  });

  expect(Object.fromEntries(bucket.objects)).toStrictEqual({
    'state:atc': 'up',
    'state:imp': 'origin-down',
  });
});

test('it posts a change of state to ALERT_URL in the content, text and message fields', async () => {
  await using target = startStubHTTPServer(530);
  await using webhook = startStubHTTPServer(204);

  await handler.scheduled(undefined, {
    STATE: buildStubR2Bucket({ 'state:atc': 'up' }),
    TARGETS: JSON.stringify([{ name: 'atc', url: target.url }]),
    ALERT_URL: webhook.url,
  });

  expect(webhook.requests).toStrictEqual([
    {
      method: 'POST',
      contentType: 'application/json',
      body: JSON.stringify({
        content: 'geoff.cloud: atc is tunnel-down (was up)',
        text: 'geoff.cloud: atc is tunnel-down (was up)',
        message: 'geoff.cloud: atc is tunnel-down (was up)',
      }),
    },
  ]);
});

test('it names the previous state unknown on a target it has not checked before', async () => {
  await using target = startStubHTTPServer(200);
  await using webhook = startStubHTTPServer(204);

  await handler.scheduled(undefined, {
    STATE: buildStubR2Bucket(),
    TARGETS: JSON.stringify([{ name: 'atc', url: target.url }]),
    ALERT_URL: webhook.url,
  });

  expect(webhook.requests).toStrictEqual([
    {
      method: 'POST',
      contentType: 'application/json',
      body: JSON.stringify({
        content: 'geoff.cloud: atc is up (was unknown)',
        text: 'geoff.cloud: atc is up (was unknown)',
        message: 'geoff.cloud: atc is up (was unknown)',
      }),
    },
  ]);
});

test('it posts nothing while the state is unchanged', async () => {
  await using target = startStubHTTPServer(200);
  await using webhook = startStubHTTPServer(204);

  await handler.scheduled(undefined, {
    STATE: buildStubR2Bucket({ 'state:atc': 'up' }),
    TARGETS: JSON.stringify([{ name: 'atc', url: target.url }]),
    ALERT_URL: webhook.url,
  });

  expect(webhook.requests).toBeEmpty();
});

test('it records a change without posting it when ALERT_URL is empty', async () => {
  await using target = startStubHTTPServer(502);

  const bucket = buildStubR2Bucket({ 'state:atc': 'up' });

  await handler.scheduled(undefined, {
    STATE: bucket,
    TARGETS: JSON.stringify([{ name: 'atc', url: target.url }]),
    ALERT_URL: '',
  });

  expect(Object.fromEntries(bucket.objects)).toStrictEqual({ 'state:atc': 'origin-down' });
});

test.each([
  ['an object', '{"name":"atc","url":"https://atc.geoff.cloud"}'],
  ['a target with no url', '[{"name":"atc"}]'],
  ['a target whose name is not a string', '[{"name":1,"url":"https://atc.geoff.cloud"}]'],
  ['a null target', '[null]'],
])('it refuses TARGETS that holds %s', (_kind, targets) => {
  expect(
    handler.scheduled(undefined, { STATE: buildStubR2Bucket(), TARGETS: targets }),
  ).rejects.toThrowWithMessage(Error, 'TARGETS must be a JSON array of { name, url }');
});

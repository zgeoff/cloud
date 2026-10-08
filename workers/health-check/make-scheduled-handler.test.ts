import { expect, mock, test } from 'bun:test';
import { http, passthrough } from 'msw';
import { buildStubR2Bucket } from '../../infra/test-utils/build-stub-r2-bucket.ts';
import { alertWebhookURL } from '../mocks/alert-webhook-url.ts';
import { server } from '../mocks/node.ts';
import { sentAlerts } from '../mocks/sent-alerts.ts';
import { targetStatuses } from '../mocks/target-statuses.ts';
import { makeScheduledHandler } from './make-scheduled-handler.ts';

function setupTest() {
  const log = mock<(message: string) => void>();

  return { log, scheduled: makeScheduledHandler({ log }) };
}

test.each([
  [530, 'tunnel-down'],
  [502, 'origin-down'],
  [504, 'origin-down'],
  [200, 'up'],
  [301, 'up'],
  [401, 'up'],
  [404, 'up'],
])('it records a target that answers %d as %s', async (status, health) => {
  const ctx = setupTest();

  targetStatuses.set('https://atc.geoff.cloud/', status);

  const bucket = buildStubR2Bucket();

  await ctx.scheduled(undefined, {
    STATE: bucket,
    TARGETS: JSON.stringify([{ name: 'atc', url: 'https://atc.geoff.cloud/' }]),
  });

  expect(Object.fromEntries(bucket.objects)).toStrictEqual({ 'state:atc': health });
  expect(ctx.log).toHaveBeenCalledExactlyOnceWith(`geoff.cloud: atc is ${health} (was unknown)`);
});

test('it records a target where nothing listens as unreachable', async () => {
  const ctx = setupTest();

  // a real connection to a port where nothing listens, not a mocked failure
  server.use(http.get('http://127.0.0.1:1/', () => passthrough()));

  const bucket = buildStubR2Bucket();

  await ctx.scheduled(undefined, {
    STATE: bucket,
    TARGETS: JSON.stringify([{ name: 'atc', url: 'http://127.0.0.1:1/' }]),
  });

  expect(Object.fromEntries(bucket.objects)).toStrictEqual({ 'state:atc': 'unreachable' });
  expect(ctx.log).toHaveBeenCalledExactlyOnceWith('geoff.cloud: atc is unreachable (was unknown)');
});

test('it records each target under its own name', async () => {
  const ctx = setupTest();

  targetStatuses.set('https://atc.geoff.cloud/', 200);
  targetStatuses.set('https://imp.geoff.cloud/', 502);

  const bucket = buildStubR2Bucket();

  await ctx.scheduled(undefined, {
    STATE: bucket,
    TARGETS: JSON.stringify([
      { name: 'atc', url: 'https://atc.geoff.cloud/' },
      { name: 'imp', url: 'https://imp.geoff.cloud/' },
    ]),
  });

  expect(Object.fromEntries(bucket.objects)).toStrictEqual({
    'state:atc': 'up',
    'state:imp': 'origin-down',
  });

  // the targets are checked concurrently, so their messages come in either order
  expect(ctx.log.mock.calls).toIncludeSameMembers([
    ['geoff.cloud: atc is up (was unknown)'],
    ['geoff.cloud: imp is origin-down (was unknown)'],
  ]);
});

test('it posts a change of state to ALERT_URL in the content, text and message fields', async () => {
  const ctx = setupTest();

  targetStatuses.set('https://atc.geoff.cloud/', 530);

  await ctx.scheduled(undefined, {
    STATE: buildStubR2Bucket({ 'state:atc': 'up' }),
    TARGETS: JSON.stringify([{ name: 'atc', url: 'https://atc.geoff.cloud/' }]),
    ALERT_URL: alertWebhookURL,
  });

  expect(sentAlerts).toStrictEqual([
    {
      contentType: 'application/json',
      body: JSON.stringify({
        content: 'geoff.cloud: atc is tunnel-down (was up)',
        text: 'geoff.cloud: atc is tunnel-down (was up)',
        message: 'geoff.cloud: atc is tunnel-down (was up)',
      }),
    },
  ]);

  expect(ctx.log).toHaveBeenCalledExactlyOnceWith('geoff.cloud: atc is tunnel-down (was up)');
});

test('it names the previous state unknown on a target it has not checked before', async () => {
  const ctx = setupTest();

  targetStatuses.set('https://atc.geoff.cloud/', 200);

  await ctx.scheduled(undefined, {
    STATE: buildStubR2Bucket(),
    TARGETS: JSON.stringify([{ name: 'atc', url: 'https://atc.geoff.cloud/' }]),
    ALERT_URL: alertWebhookURL,
  });

  expect(sentAlerts).toStrictEqual([
    {
      contentType: 'application/json',
      body: JSON.stringify({
        content: 'geoff.cloud: atc is up (was unknown)',
        text: 'geoff.cloud: atc is up (was unknown)',
        message: 'geoff.cloud: atc is up (was unknown)',
      }),
    },
  ]);

  expect(ctx.log).toHaveBeenCalledExactlyOnceWith('geoff.cloud: atc is up (was unknown)');
});

test('it posts and logs nothing while the state is unchanged', async () => {
  const ctx = setupTest();

  targetStatuses.set('https://atc.geoff.cloud/', 200);

  await ctx.scheduled(undefined, {
    STATE: buildStubR2Bucket({ 'state:atc': 'up' }),
    TARGETS: JSON.stringify([{ name: 'atc', url: 'https://atc.geoff.cloud/' }]),
    ALERT_URL: alertWebhookURL,
  });

  expect(sentAlerts).toBeEmpty();
  expect(ctx.log).not.toHaveBeenCalled();
});

test('it records a change when ALERT_URL is empty', async () => {
  const ctx = setupTest();

  targetStatuses.set('https://atc.geoff.cloud/', 502);

  const bucket = buildStubR2Bucket({ 'state:atc': 'up' });

  await ctx.scheduled(undefined, {
    STATE: bucket,
    TARGETS: JSON.stringify([{ name: 'atc', url: 'https://atc.geoff.cloud/' }]),
    ALERT_URL: '',
  });

  expect(Object.fromEntries(bucket.objects)).toStrictEqual({ 'state:atc': 'origin-down' });
  expect(ctx.log).toHaveBeenCalledExactlyOnceWith('geoff.cloud: atc is origin-down (was up)');
});

test.each([
  ['an object', '{"name":"atc","url":"https://atc.geoff.cloud"}'],
  ['a target with no url', '[{"name":"atc"}]'],
  ['a target whose name is not a string', '[{"name":1,"url":"https://atc.geoff.cloud"}]'],
  ['a null target', '[null]'],
])('it refuses TARGETS that holds %s', (_kind, targets) => {
  const ctx = setupTest();

  expect(
    ctx.scheduled(undefined, { STATE: buildStubR2Bucket(), TARGETS: targets }),
  ).rejects.toThrowWithMessage(Error, 'TARGETS must be a JSON array of { name, url }');
});

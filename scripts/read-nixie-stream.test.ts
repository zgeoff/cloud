import { expect, test } from 'bun:test';
import { HttpResponse, http } from 'msw';
import { readNixieStream } from './read-nixie-stream.ts';
import { network } from './src/test-utils/network.ts';
import { startStubNixieAPI } from './src/test-utils/start-stub-nixie-api.ts';

test('it holds the stream for the whole hold and times each keepalive', async () => {
  const stub = startStubNixieAPI({
    url: 'https://nixie.test',
    enrolCodes: [],
    sequences: [1, 2, 3],
    keepaliveMs: 50,
    closeAfterMs: null,
  });

  const result = await readNixieStream({
    url: 'https://nixie.test',
    token: stub.createSession(),
    afterSequence: 3,
    holdMs: 300,
  });

  expect(result).toStrictEqual({
    ok: true,
    value: {
      openMs: expect.toBeWithin(300, 400),
      keepalives: expect.toBeWithin(5, 8),
      longestGapMs: expect.toBeWithin(0, 100),
      opened: true,
      records: 0,
      changes: 0,
      end: 'held',
    },
  });
});

test('it counts each record after the sequence it follows from', async () => {
  const stub = startStubNixieAPI({
    url: 'https://nixie.test',
    enrolCodes: [],
    sequences: [1, 2, 3],
    keepaliveMs: 50,
    closeAfterMs: null,
  });

  const result = await readNixieStream({
    url: 'https://nixie.test',
    token: stub.createSession(),
    afterSequence: 1,
    holdMs: 100,
  });

  expect(result).toMatchObject({ ok: true, value: { records: 2, end: 'held' } });
});

test('it counts each changed event apart from the records', async () => {
  const stub = startStubNixieAPI({
    url: 'https://nixie.test',
    enrolCodes: [],
    sequences: [1],
    keepaliveMs: 50,
    closeAfterMs: null,
  });

  const reading = readNixieStream({
    url: 'https://nixie.test',
    token: stub.createSession(),
    afterSequence: 1,
    holdMs: 200,
  });

  await stub.waitForStream();

  stub.publishChanged(['spend']);

  const result = await reading;

  expect(result).toMatchObject({
    ok: true,
    value: { opened: true, records: 0, changes: 1, end: 'held' },
  });
});

test('it fails a stream that sends a live event before opened', async () => {
  const stub = startStubNixieAPI({
    url: 'https://nixie.test',
    enrolCodes: [],
    sequences: [1],
    keepaliveMs: 50,
    closeAfterMs: null,
  });

  network.use(
    http.post(
      'https://nixie.test/rpc/live/follow',
      () =>
        new HttpResponse(
          'event: message\ndata: {"json":{"kind":"changed","topics":["tasks"]}}\n\n',
          {
            headers: { 'content-type': 'text/event-stream' },
          },
        ),
    ),
  );

  const result = await readNixieStream({
    url: 'https://nixie.test',
    token: stub.createSession(),
    afterSequence: 1,
    holdMs: 200,
  });

  expect(result).toMatchObject({
    ok: true,
    value: { opened: false, end: 'failed: the stream sent a changed event before opened' },
  });
});

test('it reports a stream that nixie closes before the hold ends', async () => {
  const stub = startStubNixieAPI({
    url: 'https://nixie.test',
    enrolCodes: [],
    sequences: [1],
    keepaliveMs: 50,
    closeAfterMs: 100,
  });

  const result = await readNixieStream({
    url: 'https://nixie.test',
    token: stub.createSession(),
    afterSequence: 1,
    holdMs: 400,
  });

  expect(result).toMatchObject({
    ok: true,
    value: { openMs: expect.toBeWithin(0, 300), end: 'closed' },
  });
});

test('it reports the refusal of a session nixie does not know', async () => {
  startStubNixieAPI({
    url: 'https://nixie.test',
    enrolCodes: [],
    sequences: [1],
    keepaliveMs: 50,
    closeAfterMs: null,
  });

  const result = await readNixieStream({
    url: 'https://nixie.test',
    token: 'unknown-token',
    afterSequence: 1,
    holdMs: 100,
  });

  expect(result).toStrictEqual({ ok: false, error: 'live/follow answered 401 application/json' });
});

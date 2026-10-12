import { expect, test } from 'bun:test';
import { readNixieStream } from './read-nixie-stream.ts';
import { startStubNixieAPI } from './test-utils/start-stub-nixie-api.ts';

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
      records: 0,
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

  expect(result).toStrictEqual({ ok: false, error: 'log/follow answered 401 application/json' });
});

import { expect, test } from 'bun:test';
import { countNixieRecords } from './count-nixie-records.ts';
import { startStubNixieAPI } from './test-utils/start-stub-nixie-api.ts';

test('it counts every record across pages and keeps the sequence of the newest page', async () => {
  const stub = startStubNixieAPI({
    url: 'https://nixie.test',
    enrolCodes: [],
    sequences: Array.from({ length: 450 }, (_value, index) => index + 1),
    keepaliveMs: null,
    closeAfterMs: null,
  });

  const result = await countNixieRecords({
    url: 'https://nixie.test',
    token: stub.createSession(),
  });

  expect(result).toStrictEqual({ ok: true, value: { records: 450, readAtSequence: 450 } });
  expect(stub.calls).toStrictEqual(['conversation/read', 'conversation/read', 'conversation/read']);
});

test('it counts an empty conversation as no records', async () => {
  const stub = startStubNixieAPI({
    url: 'https://nixie.test',
    enrolCodes: [],
    sequences: [],
    keepaliveMs: null,
    closeAfterMs: null,
  });

  const result = await countNixieRecords({
    url: 'https://nixie.test',
    token: stub.createSession(),
  });

  expect(result).toStrictEqual({ ok: true, value: { records: 0, readAtSequence: 0 } });
});

test('it reports the refusal of a session nixie does not know', async () => {
  startStubNixieAPI({
    url: 'https://nixie.test',
    enrolCodes: [],
    sequences: [1],
    keepaliveMs: null,
    closeAfterMs: null,
  });

  const result = await countNixieRecords({ url: 'https://nixie.test', token: 'unknown-token' });

  expect(result).toStrictEqual({
    ok: false,
    error: 'conversation/read answered 401 UNAUTHORIZED',
  });
});

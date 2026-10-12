import { expect, test } from 'bun:test';
import { startStubNixieAPI } from './start-stub-nixie-api.ts';

test('it refuses a call without the client header with a plain-text 403, as nixie does', async () => {
  startStubNixieAPI({
    url: 'https://nixie.test',
    enrolCodes: ['ABCD-2345'],
    sequences: [],
    keepaliveMs: null,
    closeAfterMs: null,
  });

  const response = await fetch('https://nixie.test/rpc/sessions/enrol', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ json: {} }),
  });

  expect({ status: response.status, body: await response.text() }).toStrictEqual({
    status: 403,
    body: 'the client header is missing',
  });
});

test('it accepts each enrolment code once', async () => {
  const stub = startStubNixieAPI({
    url: 'https://nixie.test',
    enrolCodes: ['ABCD-2345'],
    sequences: [],
    keepaliveMs: null,
    closeAfterMs: null,
  });

  const request = {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-nixie-client': 'deploy-check' },
    body: JSON.stringify({ json: { code: 'ABCD-2345', tokenDelivery: 'bearer' } }),
  };

  const first = await fetch('https://nixie.test/rpc/sessions/enrol', request);
  const second = await fetch('https://nixie.test/rpc/sessions/enrol', request);
  const refusal: unknown = await second.json();

  expect(first.status).toBe(200);

  expect(refusal).toStrictEqual({
    json: {
      defined: true,
      code: 'ENROLMENT_CODE_INVALID',
      status: 400,
      message: 'The enrolment code is unknown, used or lapsed',
    },
  });

  expect(stub.sessions).toStrictEqual([{ sessionID: expect.toBeString(), revoked: false }]);
});

test('it refuses a revoked session as unauthorized', async () => {
  const stub = startStubNixieAPI({
    url: 'https://nixie.test',
    enrolCodes: [],
    sequences: [1],
    keepaliveMs: null,
    closeAfterMs: null,
  });

  const token = stub.createSession();

  const headers = {
    'content-type': 'application/json',
    'x-nixie-client': 'deploy-check',
    authorization: `Bearer ${token}`,
  };

  await fetch('https://nixie.test/rpc/sessions/revoke', {
    method: 'POST',
    headers,
    body: JSON.stringify({ json: { sessionID: stub.sessions[0]?.sessionID } }),
  });

  const read = await fetch('https://nixie.test/rpc/conversation/read', {
    method: 'POST',
    headers,
    body: JSON.stringify({ json: { thread: 'conversation' } }),
  });

  expect(read.status).toBe(401);
  expect(stub.sessions).toStrictEqual([{ sessionID: expect.toBeString(), revoked: true }]);
});

test('it reads the newest page before a sequence, oldest first, with the log sequence it read at', async () => {
  const stub = startStubNixieAPI({
    url: 'https://nixie.test',
    enrolCodes: [],
    sequences: [1, 2, 3, 4, 5],
    keepaliveMs: null,
    closeAfterMs: null,
  });

  const response = await fetch('https://nixie.test/rpc/conversation/read', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-nixie-client': 'deploy-check',
      authorization: `Bearer ${stub.createSession()}`,
    },
    body: JSON.stringify({ json: { thread: 'conversation', limit: 2, beforeSequence: 5 } }),
  });

  const body = (await response.json()) as {
    readonly json: { readonly records: readonly { readonly sequence: number }[] };
  };

  expect(body).toMatchObject({ json: { hasEarlier: true, readAtSequence: 5 } });
  expect(body.json.records.map((record) => record.sequence)).toStrictEqual([3, 4]);
});

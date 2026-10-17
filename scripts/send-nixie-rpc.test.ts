import { expect, test } from 'bun:test';
import { HttpResponse, http, passthrough } from 'msw';
import { findJSONField } from './find-json-field.ts';
import { server } from './mocks/node.ts';
import { sendNixieRPC } from './send-nixie-rpc.ts';
import { startStubNixieAPI } from './test-utils/start-stub-nixie-api.ts';

test('it returns the output from the json field of the answer', async () => {
  startStubNixieAPI({
    url: 'https://nixie.test',
    enrolCodes: ['ABCD-2345'],
    sequences: [],
    keepaliveMs: null,
    closeAfterMs: null,
  });

  const result = await sendNixieRPC({
    url: 'https://nixie.test',
    token: null,
    procedure: 'sessions/enrol',
    input: {
      clientActionID: '0d7f5c1e-2b4a-4c8e-9f31-6a2d8b0e4c57',
      code: 'ABCD-2345',
      deviceName: 'deploy check',
      tokenDelivery: 'bearer',
    },
    parse: (output) => output,
  });

  expect(result).toStrictEqual({
    ok: true,
    value: { sessionID: expect.toBeString(), token: expect.toBeString() },
  });
});

test('it reports the status and the code of an error nixie defines', async () => {
  startStubNixieAPI({
    url: 'https://nixie.test',
    enrolCodes: [],
    sequences: [],
    keepaliveMs: null,
    closeAfterMs: null,
  });

  const result = await sendNixieRPC({
    url: 'https://nixie.test',
    token: null,
    procedure: 'sessions/enrol',
    input: {
      clientActionID: '0d7f5c1e-2b4a-4c8e-9f31-6a2d8b0e4c57',
      code: 'WXYZ-6789',
      deviceName: 'deploy check',
      tokenDelivery: 'bearer',
    },
    parse: (output) => output,
  });

  expect(result).toStrictEqual({
    ok: false,
    error: 'sessions/enrol answered 400 ENROLMENT_CODE_INVALID',
  });
});

test('it reports a call that reaches no server', async () => {
  server.use(http.post('http://127.0.0.1:1/rpc/sessions/enrol', () => passthrough()));

  const result = await sendNixieRPC({
    url: 'http://127.0.0.1:1',
    token: null,
    procedure: 'sessions/enrol',
    input: {
      clientActionID: '0d7f5c1e-2b4a-4c8e-9f31-6a2d8b0e4c57',
      code: 'ABCD-2345',
      deviceName: 'deploy check',
      tokenDelivery: 'bearer',
    },
    parse: (output) => output,
  });

  expect(result).toStrictEqual({
    ok: false,
    error: expect.toStartWith('sessions/enrol failed: '),
  });
});

test('it reports an output that lacks what the call reads, and never prints the body that holds the token', async () => {
  startStubNixieAPI({
    url: 'https://nixie.test',
    enrolCodes: ['ABCD-2345'],
    sequences: [],
    keepaliveMs: null,
    closeAfterMs: null,
  });

  const result = await sendNixieRPC({
    url: 'https://nixie.test',
    token: null,
    procedure: 'sessions/enrol',
    input: {
      clientActionID: '0d7f5c1e-2b4a-4c8e-9f31-6a2d8b0e4c57',
      code: 'ABCD-2345',
      deviceName: 'deploy check',
      tokenDelivery: 'bearer',
    },
    parse: (output) => findJSONField(output, 'sessionToken'),
  });

  expect(result).toStrictEqual({
    ok: false,
    error: 'sessions/enrol answered an output that lacks the fields the check reads',
  });
});

test('it reports a body that breaks off after the headers', async () => {
  server.use(
    http.post('https://nixie.test/rpc/conversation/read', () => {
      const body = new ReadableStream({
        // a start that rejects errors the body, as a connection closed mid-body does
        start: () => Promise.reject(new Error('the ingress closed the connection')),
      });

      return new HttpResponse(body, { headers: { 'content-type': 'application/json' } });
    }),
  );

  const result = await sendNixieRPC({
    url: 'https://nixie.test',
    token: 'a7c3e9f1-token',
    procedure: 'conversation/read',
    input: { thread: 'conversation' },
    parse: (output) => output,
  });

  expect(result).toStrictEqual({
    ok: false,
    error: 'conversation/read answered 200 with a body that broke off',
  });
});

test('it reports an error status without the body when nixie defines no code', async () => {
  server.use(
    http.post('https://nixie.test/rpc/conversation/read', () =>
      HttpResponse.text('<html>bad gateway, token a7c3e9f1</html>', { status: 502 }),
    ),
  );

  const result = await sendNixieRPC({
    url: 'https://nixie.test',
    token: 'a7c3e9f1-token',
    procedure: 'conversation/read',
    input: { thread: 'conversation' },
    parse: (output) => output,
  });

  expect(result).toStrictEqual({
    ok: false,
    error: 'conversation/read answered 502 with no error code',
  });
});

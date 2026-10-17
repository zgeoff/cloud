import { expect, test } from 'bun:test';
import { decodeNixieAnswer, encodeNixieRequest } from './nixie-rpc.ts';

test('#encodeNixieRequest builds a sessions/enrol call as oRPC encodes it', async () => {
  const request = await encodeNixieRequest({
    url: 'https://nixie.test',
    token: null,
    procedure: 'sessions/enrol',
    input: {
      clientActionID: '0d7f5c1e-2b4a-4c8e-9f31-6a2d8b0e4c57',
      code: 'ABCD-2345',
      deviceName: 'deploy check',
      tokenDelivery: 'bearer',
    },
  });

  expect({
    method: request.method,
    url: request.url,
    headers: Object.fromEntries(request.headers),
    body: await request.text(),
  }).toStrictEqual({
    method: 'POST',
    url: 'https://nixie.test/rpc/sessions/enrol',
    headers: { 'content-type': 'application/json', 'x-nixie-client': 'deploy-check' },
    body: '{"json":{"clientActionID":"0d7f5c1e-2b4a-4c8e-9f31-6a2d8b0e4c57","code":"ABCD-2345","deviceName":"deploy check","tokenDelivery":"bearer"}}',
  });
});

test('#encodeNixieRequest builds a log/follow call with the session token', async () => {
  const request = await encodeNixieRequest({
    url: 'https://nixie.test',
    token: 'a7c3e9f1-token',
    procedure: 'log/follow',
    input: { afterSequence: 3, thread: 'conversation' },
  });

  expect({
    method: request.method,
    url: request.url,
    headers: Object.fromEntries(request.headers),
    body: await request.text(),
  }).toStrictEqual({
    method: 'POST',
    url: 'https://nixie.test/rpc/log/follow',
    headers: {
      authorization: 'Bearer a7c3e9f1-token',
      'content-type': 'application/json',
      'x-nixie-client': 'deploy-check',
    },
    body: '{"json":{"afterSequence":3,"thread":"conversation"}}',
  });
});

test('#encodeNixieRequest builds a request that the caller can stop', async () => {
  const stopping = new AbortController();

  stopping.abort();

  const request = await encodeNixieRequest({
    url: 'https://nixie.test',
    token: 'a7c3e9f1-token',
    procedure: 'log/follow',
    input: { afterSequence: 3, thread: 'conversation' },
    signal: stopping.signal,
  });

  expect(request.signal.aborted).toBeTrue();
});

test('#decodeNixieAnswer decodes the output of a successful answer, with the types its meta names', async () => {
  const answer = await decodeNixieAnswer(
    200,
    '{"json":{"sessionID":"6f1c2a9e-4d3b-4e8a-9c71-2b5d8e0f3a14","at":"2026-10-17T09:30:00.000Z"},"meta":[[1,"at"]]}',
  );

  expect(answer).toStrictEqual({
    ok: true,
    output: {
      sessionID: '6f1c2a9e-4d3b-4e8a-9c71-2b5d8e0f3a14',
      at: new Date('2026-10-17T09:30:00.000Z'),
    },
  });
});

test('#decodeNixieAnswer reads the code of an error nixie defines', async () => {
  const answer = await decodeNixieAnswer(
    400,
    '{"json":{"defined":true,"code":"ENROLMENT_CODE_INVALID","status":400,"message":"The enrolment code is unknown, used or lapsed"}}',
  );

  expect(answer).toStrictEqual({ ok: false, code: 'ENROLMENT_CODE_INVALID' });
});

test('#decodeNixieAnswer reports no code for an error body that is not JSON', async () => {
  const answer = await decodeNixieAnswer(502, '<html>bad gateway</html>');

  expect(answer).toStrictEqual({ ok: false, code: null });
});

test('#decodeNixieAnswer reports no code for a successful body that is not in the RPC protocol', async () => {
  const answer = await decodeNixieAnswer(200, 'null');

  expect(answer).toStrictEqual({ ok: false, code: null });
});

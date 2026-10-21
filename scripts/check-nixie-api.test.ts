import { expect, mock, test } from 'bun:test';
import { HttpResponse, http, passthrough } from 'msw';
import { checkNixieAPI } from './check-nixie-api.ts';
import { server } from './mocks/node.ts';
import { startStubNixieAPI } from './test-utils/start-stub-nixie-api.ts';

function setupTest() {
  return {
    printOut: mock<(text: string) => void>(),
    printErr: mock<(text: string) => void>(),
  };
}

test('it passes when nixie refuses each call for want of a session', async () => {
  const ctx = setupTest();

  const stub = startStubNixieAPI({
    url: 'https://proxy.test/api/v1/namespaces/nixie/services/http:nixie:http/proxy',
    enrolCodes: [],
    sequences: [1, 2],
    keepaliveMs: null,
    closeAfterMs: null,
  });

  const exitCode = await checkNixieAPI({
    url: 'https://proxy.test/api/v1/namespaces/nixie/services/http:nixie:http/proxy',
    calls: [
      { procedure: 'sessions/list', input: undefined },
      { procedure: 'conversation/read', input: { thread: 'conversation', limit: 1 } },
    ],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(0);
  expect(stub.calls).toIncludeSameMembers(['sessions/list', 'conversation/read']);
  expect(ctx.printErr).not.toHaveBeenCalled();

  expect(ctx.printOut.mock.calls).toStrictEqual([
    ['sessions/list: refused without a session, as the contract says\n'],
    ['conversation/read: refused without a session, as the contract says\n'],
    ['nixie API check passed\n'],
  ]);
});

test('it fails on a procedure that nixie no longer serves', async () => {
  const ctx = setupTest();

  startStubNixieAPI({
    url: 'https://nixie.test',
    enrolCodes: [],
    sequences: [],
    keepaliveMs: null,
    closeAfterMs: null,
  });

  // nixie 0.39.1's API app (modules/api/src/create-api-app.ts) answers a path that matches no
  // procedure itself, in plain text
  server.use(
    http.post(
      'https://nixie.test/rpc/sessions/list',
      () => new HttpResponse('not found', { status: 404 }),
    ),
  );

  const exitCode = await checkNixieAPI({
    url: 'https://nixie.test',
    calls: [
      { procedure: 'sessions/list', input: undefined },
      { procedure: 'conversation/read', input: { thread: 'conversation', limit: 1 } },
    ],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'check-nixie-api: sessions/list answered 404 with no error code, not 401 UNAUTHORIZED\n',
  );

  expect(ctx.printOut).toHaveBeenCalledExactlyOnceWith(
    'conversation/read: refused without a session, as the contract says\n',
  );
});

test('it fails on a call that nixie answers without a session, and never prints the output', async () => {
  const ctx = setupTest();

  server.use(
    http.post('https://nixie.test/rpc/sessions/list', () =>
      HttpResponse.json({ json: { sessions: [] } }),
    ),
  );

  const exitCode = await checkNixieAPI({
    url: 'https://nixie.test',
    calls: [{ procedure: 'sessions/list', input: undefined }],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);
  expect(ctx.printOut).not.toHaveBeenCalled();

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'check-nixie-api: sessions/list answered 200 with an output to a call without a session\n',
  );
});

test('it fails on a call that reaches no server', async () => {
  const ctx = setupTest();

  server.use(http.post('http://127.0.0.1:1/rpc/sessions/list', () => passthrough()));

  const exitCode = await checkNixieAPI({
    url: 'http://127.0.0.1:1',
    calls: [{ procedure: 'sessions/list', input: undefined }],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    expect.toStartWith('check-nixie-api: sessions/list failed: '),
  );
});

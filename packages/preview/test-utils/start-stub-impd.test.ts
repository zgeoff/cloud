/* oxlint-disable max-lines-per-function, max-statements, typescript/no-unsafe-type-assertion */
import { expect, test } from 'bun:test';
import { NativeWebSocket } from '../mocks/native-web-socket.ts';
import { startStubImpd } from './start-stub-impd.ts';

test('it answers a procedure in the oRPC envelope', async () => {
  const impd = startStubImpd();

  const response = await fetch(`${impd.url}/rpc/imps/create`, {
    method: 'POST',
    headers: { authorization: `Bearer ${impd.token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ json: { name: 'pv-0a1b2c3d-17', image: 'base', memoryMib: 2048 } }),
  });

  expect(response.status).toBe(200);

  const result = await response.json();

  expect(result).toStrictEqual({
    json: {
      id: 'imp-pv-0a1b2c3d-17',
      name: 'pv-0a1b2c3d-17',
      image: 'base',
      state: 'running',
      httpPort: 8080,
      lastActiveAt: null,
    },
  });
});

test('it lists the secrets granted to an imp, as impd grants.list does', async () => {
  const impd = startStubImpd();

  impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    lastActiveAt: null,
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  const response = await fetch(`${impd.url}/rpc/grants/list`, {
    method: 'POST',
    headers: { authorization: `Bearer ${impd.token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ json: { name: 'pv-0a1b2c3d-17' } }),
  });

  const result = await response.json();

  expect(result).toStrictEqual({ json: ['gh'] });
});

test('it answers an unknown imp with oRPC NOT_FOUND error body', async () => {
  const impd = startStubImpd();

  const response = await fetch(`${impd.url}/rpc/imps/get`, {
    method: 'POST',
    headers: { authorization: `Bearer ${impd.token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ json: { name: 'pv-0a1b2c3d-17' } }),
  });

  expect(response.status).toBe(404);

  const result = await response.json();

  expect(result).toStrictEqual({
    json: { defined: true, code: 'NOT_FOUND', status: 404, message: 'no imp named pv-0a1b2c3d-17' },
  });
});

test('it refuses a call without its token', async () => {
  const impd = startStubImpd();

  const response = await fetch(`${impd.url}/rpc/imps/list`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ json: {} }),
  });

  expect(response.status).toBe(401);
});

test('it fails closed on a procedure it does not model', async () => {
  const impd = startStubImpd();

  impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    lastActiveAt: null,
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: [],
  });

  const response = await fetch(`${impd.url}/rpc/imps/expose`, {
    method: 'POST',
    headers: { authorization: `Bearer ${impd.token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ json: { name: 'pv-0a1b2c3d-17' } }),
  });

  const text = await response.text();

  expect(response.status).toBe(500);
  expect(text).toBe('not impd: start-stub-impd.ts has no imps/expose\n');
});

test('it runs a guest command over the exec protocol and wakes the imp', async () => {
  const impd = startStubImpd();

  impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'sleeping',
    lastActiveAt: null,
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: [],
  });

  impd.answerCommand = () => ({ code: 0, stdout: 'ok\n' });

  const socket = new NativeWebSocket(`${impd.url.replace('http', 'ws')}/exec`, {
    headers: { authorization: `Bearer ${impd.token}` },
  });

  socket.binaryType = 'arraybuffer';

  const messages: string[] = [];
  const closed = Promise.withResolvers<void>();

  socket.addEventListener('close', () => {
    closed.resolve();
  });

  socket.addEventListener('open', () => {
    socket.send(
      JSON.stringify({ type: 'start', name: 'pv-0a1b2c3d-17', argv: ['true'], tty: false }),
    );
  });

  socket.addEventListener('message', (event) => {
    const message =
      typeof event.data === 'string'
        ? event.data
        : `frame ${new Uint8Array(event.data as ArrayBuffer)[0]}: ${new TextDecoder().decode(new Uint8Array(event.data as ArrayBuffer).subarray(1))}`;

    messages.push(message);
  });

  await closed.promise;

  expect(messages).toStrictEqual([
    '{"type":"started","pid":4242}',
    'frame 1: ok\n',
    '{"type":"exit","code":0,"signal":null}',
  ]);

  expect(impd.imps.get('pv-0a1b2c3d-17')?.state).toBe('running');
});

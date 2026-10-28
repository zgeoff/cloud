import { expect, test } from 'bun:test';
import { z } from 'zod';
import { startStubImpd } from './start-stub-impd.ts';

test('it answers a procedure in the oRPC envelope, with each date named in meta', async () => {
  const impd = startStubImpd();

  impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: [],
  });

  const response = await fetch(`${impd.url}/rpc/imps/list`, {
    method: 'POST',
    headers: { authorization: `Bearer ${impd.token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ json: {} }),
  });

  expect(response.status).toBe(200);

  const result = await response.json();

  expect(result).toStrictEqual({
    json: [
      {
        id: 'imp-pv-0a1b2c3d-17',
        name: 'pv-0a1b2c3d-17',
        image: 'base',
        state: 'running',
        httpPort: 8080,
        lastActiveAt: '2026-10-15T08:00:00.000Z',
      },
    ],
    meta: [[1, 0, 'lastActiveAt']],
  });
});

test('it creates an imp active from its creation, as impd does', async () => {
  const impd = startStubImpd();
  const before = Date.now();

  const response = await fetch(`${impd.url}/rpc/imps/create`, {
    method: 'POST',
    headers: { authorization: `Bearer ${impd.token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ json: { name: 'pv-0a1b2c3d-17', image: 'base', memoryMib: 2048 } }),
  });

  const body = await response.json();

  const result = z.object({ json: z.object({ lastActiveAt: z.string() }) }).parse(body);

  expect(new Date(result.json.lastActiveAt)).toBeBetween(new Date(before), new Date());
});

test('it reports a version and the exec requirement check from system.info, which takes no body', async () => {
  const impd = startStubImpd();

  const response = await fetch(`${impd.url}/rpc/system/info`, {
    method: 'POST',
    headers: { authorization: `Bearer ${impd.token}` },
  });

  const result = await response.json();

  expect(result).toStrictEqual({ json: { version: '2.3.0', features: { execRequire: true } } });
});

test('it lists the secrets granted to an imp, as impd grants.list does', async () => {
  const impd = startStubImpd();

  impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
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

test('it grants a secret once and records the path filter of each later grant, as impd grants.add does', async () => {
  const impd = startStubImpd();

  impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['preview-model-counted'],
  });

  await fetch(`${impd.url}/rpc/grants/add`, {
    method: 'POST',
    headers: { authorization: `Bearer ${impd.token}`, 'content-type': 'application/json' },
    body: JSON.stringify({
      json: {
        name: 'pv-0a1b2c3d-17',
        secret: 'preview-model-counted',
        filter: { paths: ['/pv-0a1b2c3d-17/**'] },
      },
    }),
  });

  expect(impd.imps.get('pv-0a1b2c3d-17')?.grants).toStrictEqual(['preview-model-counted']);

  expect(impd.grantPaths).toStrictEqual(
    new Map([['pv-0a1b2c3d-17 preview-model-counted', ['/pv-0a1b2c3d-17/**']]]),
  );
});

test('it refuses a grant whose host another grant of the imp covers, as impd grants.add does', async () => {
  const impd = startStubImpd();

  impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['model-sonnet'],
  });

  impd.secretHosts.set('model-sonnet', 'models.example.test');
  impd.secretHosts.set('model-sonnet-counted', 'models.example.test');

  const response = await fetch(`${impd.url}/rpc/grants/add`, {
    method: 'POST',
    headers: { authorization: `Bearer ${impd.token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ json: { name: 'pv-0a1b2c3d-17', secret: 'model-sonnet-counted' } }),
  });

  const result = await response.json();

  expect(response.status).toBe(409);

  expect(result).toStrictEqual({
    json: {
      defined: true,
      code: 'CONFLICT',
      status: 409,
      message:
        'secret model-sonnet already gives pv-0a1b2c3d-17 a credential for models.example.test',
    },
  });

  expect(impd.imps.get('pv-0a1b2c3d-17')?.grants).toStrictEqual(['model-sonnet']);
});

test('it removes a grant and its path filter, as impd grants.delete does', async () => {
  const impd = startStubImpd();

  impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh', 'model-sonnet'],
  });

  impd.grantPaths.set('pv-0a1b2c3d-17 model-sonnet', ['/pv-0a1b2c3d-17/**']);

  const response = await fetch(`${impd.url}/rpc/grants/delete`, {
    method: 'POST',
    headers: { authorization: `Bearer ${impd.token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ json: { name: 'pv-0a1b2c3d-17', secret: 'model-sonnet' } }),
  });

  expect(response.status).toBe(200);
  expect(impd.imps.get('pv-0a1b2c3d-17')?.grants).toStrictEqual(['gh']);
  expect(impd.grantPaths).toStrictEqual(new Map());
});

test('it answers the removal of a grant the imp lacks with oRPC NOT_FOUND error body', async () => {
  const impd = startStubImpd();

  impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  const response = await fetch(`${impd.url}/rpc/grants/delete`, {
    method: 'POST',
    headers: { authorization: `Bearer ${impd.token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ json: { name: 'pv-0a1b2c3d-17', secret: 'model-sonnet' } }),
  });

  const result = await response.json();

  expect(response.status).toBe(404);

  expect(result).toStrictEqual({
    json: {
      defined: true,
      code: 'NOT_FOUND',
      status: 404,
      message: 'pv-0a1b2c3d-17 holds no grant of model-sonnet',
    },
  });
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
    lastActiveAt: '2026-10-15T08:00:00.000Z',
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

test('it refuses a procedure whose input is not an object with oRPC BAD_REQUEST error body', async () => {
  const impd = startStubImpd();

  const response = await fetch(`${impd.url}/rpc/imps/list`, {
    method: 'POST',
    headers: { authorization: `Bearer ${impd.token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ json: ['pv-0a1b2c3d-17'] }),
  });

  expect(response.status).toBe(400);

  const result = await response.json();

  expect(result).toStrictEqual({
    json: { defined: true, code: 'BAD_REQUEST', status: 400, message: 'Input validation failed' },
  });
});

test('it redeems an exec ticket once and refuses it with a 401 after', async () => {
  const impd = startStubImpd();

  impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: [],
  });

  const issued = await fetch(`${impd.url}/rpc/exec/ticket`, {
    method: 'POST',
    headers: { authorization: `Bearer ${impd.token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ json: { name: 'pv-0a1b2c3d-17' } }),
  });

  const issuedBody = await issued.json();

  const result = z.object({ json: z.object({ ticket: z.string() }) }).parse(issuedBody);

  const first = await fetch(`${impd.url}/exec?ticket=${result.json.ticket}`);
  const second = await fetch(`${impd.url}/exec?ticket=${result.json.ticket}`);

  expect(first.status).toBe(400);
  expect(second.status).toBe(401);
});

test.each([
  { label: 'no ticket and no token', path: '/exec', headers: {} },
  { label: 'a ticket impd never issued', path: '/exec?ticket=tk-never-issued', headers: {} },
  { label: 'another bearer token', path: '/exec', headers: { authorization: 'Bearer tk-other' } },
])('it refuses an exec opened with $label with a 401', async (row) => {
  const impd = startStubImpd();

  const response = await fetch(`${impd.url}${row.path}`, { headers: row.headers });
  const body = await response.json();

  expect(response.status).toBe(401);
  expect(body).toStrictEqual({ error: 'unauthorized' });
});

test('it runs a guest command opened with a ticket, with both streams, and wakes the imp', async () => {
  const impd = startStubImpd();

  impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'sleeping',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: [],
  });

  impd.answerCommand = () => ({ code: 0, stdout: 'ok\n', stderr: 'warn\n' });

  const issued = await fetch(`${impd.url}/rpc/exec/ticket`, {
    method: 'POST',
    headers: { authorization: `Bearer ${impd.token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ json: { name: 'pv-0a1b2c3d-17' } }),
  });

  const issuedBody = await issued.json();

  const result = z.object({ json: z.object({ ticket: z.string() }) }).parse(issuedBody);

  const socket = new WebSocket(
    `${impd.url.replace('http', 'ws')}/exec?ticket=${result.json.ticket}`,
  );

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
      event.data instanceof ArrayBuffer
        ? `frame ${new Uint8Array(event.data)[0]}: ${new TextDecoder().decode(new Uint8Array(event.data).subarray(1))}`
        : String(event.data);

    messages.push(message);
  });

  await closed.promise;

  expect(messages).toStrictEqual([
    '{"type":"started","pid":4242}',
    'frame 1: ok\n',
    'frame 2: warn\n',
    '{"type":"exit","code":0,"signal":null}',
  ]);

  expect(impd.imps.get('pv-0a1b2c3d-17')?.state).toBe('running');
});

test('it runs a guest command opened with the bearer token', async () => {
  const impd = startStubImpd();

  impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'sleeping',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: [],
  });

  impd.answerCommand = () => ({ code: 0, stdout: 'ok\n' });

  const socket = new WebSocket(`${impd.url.replace('http', 'ws')}/exec`, {
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
      event.data instanceof ArrayBuffer
        ? `frame ${new Uint8Array(event.data)[0]}: ${new TextDecoder().decode(new Uint8Array(event.data).subarray(1))}`
        : String(event.data);

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

test('it refuses an exec start whose argv is not a list of strings, and records no command', async () => {
  const impd = startStubImpd();

  impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: [],
  });

  const socket = new WebSocket(`${impd.url.replace('http', 'ws')}/exec`, {
    headers: { authorization: `Bearer ${impd.token}` },
  });

  const messages: string[] = [];
  const closed = Promise.withResolvers<void>();

  socket.addEventListener('close', () => {
    closed.resolve();
  });

  socket.addEventListener('open', () => {
    socket.send(JSON.stringify({ type: 'start', name: 'pv-0a1b2c3d-17', argv: [42], tty: false }));
  });

  socket.addEventListener('message', (event) => {
    messages.push(String(event.data));
  });

  await closed.promise;

  expect(messages).toStrictEqual([
    '{"type":"error","code":"BAD_REQUEST","message":"not an exec message"}',
  ]);

  expect(impd.commands).toStrictEqual([]);
});

test('it holds a command open without an exit until its imp is destroyed', async () => {
  const impd = startStubImpd();

  impd.imps.set('pv-sdk-0123456789abcdef', {
    name: 'pv-sdk-0123456789abcdef',
    state: 'running',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: [],
  });

  impd.answerCommand = () => ({ code: null, hold: true });

  const socket = new WebSocket(`${impd.url.replace('http', 'ws')}/exec`, {
    headers: { authorization: `Bearer ${impd.token}` },
  });

  const messages: string[] = [];
  const started = Promise.withResolvers<void>();
  const closed = Promise.withResolvers<void>();

  socket.addEventListener('close', () => {
    closed.resolve();
  });

  socket.addEventListener('open', () => {
    socket.send(
      JSON.stringify({
        type: 'start',
        name: 'pv-sdk-0123456789abcdef',
        argv: ['sleep', 'infinity'],
        tty: false,
      }),
    );
  });

  socket.addEventListener('message', (event) => {
    messages.push(String(event.data));
    started.resolve();
  });

  await started.promise;

  await fetch(`${impd.url}/rpc/imps/destroy`, {
    method: 'POST',
    headers: { authorization: `Bearer ${impd.token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ json: { name: 'pv-sdk-0123456789abcdef' } }),
  });

  await closed.promise;

  expect(messages).toStrictEqual(['{"type":"started","pid":4242}']);
});

test("it serves impd's wake proxy under its domain through MSW", async () => {
  const impd = startStubImpd();

  impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'sleeping',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 3000,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: [],
  });

  impd.apps.set('pv-0a1b2c3d-17', { address: '0.0.0.0', port: 3000 });

  const response = await fetch('https://pv-0a1b2c3d-17.imps.example.test/healthz');

  expect({ status: response.status, body: await response.text() }).toStrictEqual({
    status: 200,
    body: 'ok\n',
  });

  expect(impd.imps.get('pv-0a1b2c3d-17')?.state).toBe('running');
  expect(impd.proxied).toStrictEqual(['GET https://pv-0a1b2c3d-17.imps.example.test/healthz']);
});

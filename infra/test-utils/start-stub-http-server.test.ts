import { expect, test } from 'bun:test';
import { startStubHTTPServer } from './start-stub-http-server.ts';

test('it answers every request with its status', async () => {
  await using server = startStubHTTPServer(530);

  const response = await fetch(server.url);

  expect(response.status).toBe(530);
});

test('it sends a Location header with a redirect status', async () => {
  await using server = startStubHTTPServer(301);

  const response = await fetch(server.url, { redirect: 'manual' });

  expect(response.headers.get('location')).toBe('https://example.invalid/');
});

test("it records each request's method, content type and body", async () => {
  await using server = startStubHTTPServer(204);

  await fetch(server.url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: '{"content":"down"}',
  });

  expect(server.requests).toStrictEqual([
    { method: 'POST', contentType: 'application/json', body: '{"content":"down"}' },
  ]);
});

test('it stops listening once disposed', async () => {
  const server = startStubHTTPServer(200);
  const url = server.url;

  await server[Symbol.asyncDispose]();

  expect(fetch(url)).rejects.toThrow();
});

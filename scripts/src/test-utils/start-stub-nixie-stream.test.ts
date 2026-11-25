import { expect, onTestFinished, test } from 'bun:test';
import { startStubNixieStream } from './start-stub-nixie-stream.ts';

test('it opens with an empty comment and writes each live event as a message event, a record with its sequence as the id, as oRPC 1.15.4 does', async () => {
  const stream = startStubNixieStream({
    keepaliveMs: null,
    closeAfterMs: null,
    signal: new AbortController().signal,
  });

  onTestFinished(() => {
    stream.stop();
  });

  stream.sendOpened();
  stream.sendRecord(4);
  stream.sendChanged(['tasks']);
  stream.stop();

  const text = await new Response(stream.body).text();

  expect(text).toBe(
    [
      ': \n\n',
      'event: message\ndata: {"json":{"kind":"opened"}}\n\n',
      'event: message\nid: 4\ndata: {"json":{"kind":"record","record":{"kind":"message","message":{"text":"record 4"},"recordedAt":"2026-10-12T00:00:04.000Z","sequence":4,"thread":"conversation"}},"meta":[[1,"record","recordedAt"]]}\n\n',
      'event: message\ndata: {"json":{"kind":"changed","topics":["tasks"]}}\n\n',
    ].join(''),
  );
});

test('it sends an empty comment at each keepalive', async () => {
  const stream = startStubNixieStream({
    keepaliveMs: 20,
    closeAfterMs: 110,
    signal: new AbortController().signal,
  });

  onTestFinished(() => {
    stream.stop();
  });

  const text = await new Response(stream.body).text();

  expect(text).toBeOneOf([': \n\n'.repeat(5), ': \n\n'.repeat(6)]);
});

test('it ends the stream when the client aborts', async () => {
  const leaving = new AbortController();

  const stream = startStubNixieStream({
    keepaliveMs: 20,
    closeAfterMs: null,
    signal: leaving.signal,
  });

  onTestFinished(() => {
    stream.stop();
  });

  leaving.abort();

  const text = await new Response(stream.body).text();

  expect(text).toBe(': \n\n');
});

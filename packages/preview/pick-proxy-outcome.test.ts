import { expect, test } from 'bun:test';
import { pickProxyOutcome } from './pick-proxy-outcome.ts';

test('it refuses a call whose proxy did not start, with no hold to release', () => {
  expect(pickProxyOutcome(null, null)).toStrictEqual({
    kind: 'refuse',
    refusal: { kind: 'no-proxy' },
    holdToRelease: null,
  });
});

test('it refuses a call that the proxy did not answer, and releases its hold', () => {
  const hold = { origin: 'http://127.0.0.1:41000', release: () => {} };

  expect(pickProxyOutcome(hold, null)).toStrictEqual({
    kind: 'refuse',
    refusal: { kind: 'no-answer' },
    holdToRelease: hold,
  });
});

test('it forwards an answer with no body and releases its hold at once', () => {
  const hold = { origin: 'http://127.0.0.1:41000', release: () => {} };

  const answer = new Response(null, { status: 204 });

  expect(pickProxyOutcome(hold, answer)).toStrictEqual({
    kind: 'forward',
    answer,
    hold,
    watchedBody: null,
    holdToRelease: hold,
  });
});

test('it forwards an answer with a body and keeps its hold until the body ends', () => {
  const hold = { origin: 'http://127.0.0.1:41000', release: () => {} };

  const answer = new Response('event: message_start\n\n', { status: 200 });

  expect(pickProxyOutcome(hold, answer)).toStrictEqual({
    kind: 'forward',
    answer,
    hold,
    watchedBody: answer.body,
    holdToRelease: null,
  });
});

test('it forwards a refusal from the proxy as an answer, not as its own refusal', () => {
  const hold = { origin: 'http://127.0.0.1:41000', release: () => {} };
  const answer = Response.json({ type: 'error' }, { status: 403 });

  expect(pickProxyOutcome(hold, answer)).toMatchObject({ kind: 'forward', answer });
});

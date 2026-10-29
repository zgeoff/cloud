import { expect, test } from 'bun:test';
import { buildForwardedHeaders } from './build-forwarded-headers.ts';

test('it drops the hop-by-hop and body length headers from a call and keeps the rest', () => {
  const headers = buildForwardedHeaders(
    new Headers({
      host: '10.88.0.1:18082',
      connection: 'keep-alive',
      'keep-alive': 'timeout=5',
      'transfer-encoding': 'chunked',
      'content-length': '23',
      'content-encoding': 'gzip',
      authorization: 'Bearer placeholder-credential',
    }),
    'call',
  );

  expect(Object.fromEntries(headers)).toStrictEqual({
    'content-encoding': 'gzip',
    authorization: 'Bearer placeholder-credential',
  });
});

test('it drops the content encoding from an answer as well', () => {
  const headers = buildForwardedHeaders(
    new Headers({
      connection: 'keep-alive',
      'content-length': '23',
      'content-encoding': 'gzip',
      'content-type': 'application/json',
    }),
    'answer',
  );

  expect(Object.fromEntries(headers)).toStrictEqual({ 'content-type': 'application/json' });
});

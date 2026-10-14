import { expect, test } from 'bun:test';
import { runProcess } from '../run-process.ts';
import { startStubImpd } from './start-stub-impd.ts';

// real curl asks the stand-in, as the host script's curl does, and prints the body, then the status

test('it answers the good token’s whoami with atc-cloud’s identity in imp’s json envelope', async () => {
  const impd = startStubImpd('imp_fixture_good');

  const result = await runProcess([
    'curl',
    '-q',
    '-sS',
    '-H',
    'Authorization: Bearer imp_fixture_good',
    '--data',
    '{"json":{}}',
    '-w',
    '\n%{http_code}',
    `http://127.0.0.1:${impd.port}/rpc/tokens/whoami`,
  ]);

  expect(result.stdout.toString()).toBe(
    '{"json":{"kind":"token","name":"atc-cloud","scope":"manage","imps":["harness-*"],"grantable":["glm"]}}\n200',
  );

  expect(impd.requests).toStrictEqual([
    {
      method: 'POST',
      target: '/rpc/tokens/whoami',
      authorization: 'Bearer imp_fixture_good',
      body: '{"json":{}}',
    },
  ]);
});

test('it answers any other bearer with impd’s 401', async () => {
  const impd = startStubImpd('imp_fixture_good');

  const result = await runProcess([
    'curl',
    '-q',
    '-sS',
    '-H',
    'Authorization: Bearer imp_fixture_stale',
    '--data',
    '{"json":{}}',
    '-w',
    '\n%{http_code}',
    `http://127.0.0.1:${impd.port}/rpc/tokens/whoami`,
  ]);

  expect(result.stdout.toString()).toBe('{"error":"unauthorized"}\n401');
});

test('it answers /health as ready by default', async () => {
  const impd = startStubImpd('imp_fixture_good');

  const result = await runProcess(
    ['curl', '-q', '-sS', '-w', '\n%{http_code}', `http://127.0.0.1:${impd.port}/health`],
    { env: { PATH: process.env['PATH'] } },
  );

  expect(result.stdout.toString()).toBe('{"ready":true}\n200');

  expect(impd.requests).toStrictEqual([
    { method: 'GET', target: '/health', authorization: null, body: '' },
  ]);
});

test('it answers /health with the status and body a test gives it', async () => {
  const impd = startStubImpd('imp_fixture_good', { status: 503, body: '{"ready":false}' });

  const result = await runProcess(
    ['curl', '-q', '-sS', '-w', '\n%{http_code}', `http://127.0.0.1:${impd.port}/health`],
    { env: { PATH: process.env['PATH'] } },
  );

  expect(result.stdout.toString()).toBe('{"ready":false}\n503');
});

test('it fails closed for any other request, and records a proxy request’s whole URL', async () => {
  const impd = startStubImpd('imp_fixture_good');

  // only PATH, so no proxy variable of the caller's sends the request elsewhere
  const result = await runProcess(
    [
      'curl',
      '-q',
      '-sS',
      '--proxy',
      `http://127.0.0.1:${impd.port}`,
      '-w',
      '\n%{http_code}',
      'http://impd.invalid/rpc/tokens/whoami',
    ],
    { env: { PATH: process.env['PATH'] } },
  );

  expect(result.stdout.toString()).toBe('not impd: start-stub-impd.ts\n\n500');

  expect(impd.requests).toStrictEqual([
    {
      method: 'GET',
      target: 'http://impd.invalid/rpc/tokens/whoami',
      authorization: null,
      body: '',
    },
  ]);
});

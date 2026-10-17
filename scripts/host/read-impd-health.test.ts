import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runProcess } from '../run-process.ts';
import { startStubImpd } from '../test-utils/start-stub-impd.ts';

// The script runs as the host gets it, with real bash reading it on stdin, and real curl asks the
// impd stand-in on loopback
async function setupTest() {
  const dir = await mkdtemp(join(tmpdir(), 'read-impd-health-'));

  onTestFinished(() => rm(dir, { recursive: true, force: true }));

  const script = await readFile(new URL('read-impd-health.sh', import.meta.url));

  return { dir, script, env: { PATH: process.env['PATH'] ?? '/usr/bin:/bin', HOME: dir } };
}

test('it prints the status and then impd’s body for an impd that is ready', async () => {
  const ctx = await setupTest();

  const impd = startStubImpd('imp_fixture_good', {
    status: 200,
    body: '{"status":"ok","ready":true,"warnings":[]}',
  });

  const result = await runProcess(['bash', '-s', '--', String(impd.port)], {
    stdin: ctx.script,
    env: ctx.env,
  });

  expect(result).toStrictEqual({
    exitCode: 0,
    stdout: Buffer.from('200\n{"status":"ok","ready":true,"warnings":[]}'),
    stderr: Buffer.from(''),
    timedOut: false,
  });

  expect(impd.requests).toStrictEqual([
    { method: 'GET', target: '/health', authorization: null, body: '' },
  ]);
});

test('it prints the status and then impd’s body for an impd that is not ready', async () => {
  const ctx = await setupTest();

  const impd = startStubImpd('imp_fixture_good', { status: 503, body: '{"ready":false}' });

  const result = await runProcess(['bash', '-s', '--', String(impd.port)], {
    stdin: ctx.script,
    env: ctx.env,
  });

  expect(result.stdout.toString()).toBe('503\n{"ready":false}');
});

test('it prints no more than 64 KiB of the body', async () => {
  const ctx = await setupTest();

  const impd = startStubImpd('imp_fixture_good', { status: 200, body: 'x'.repeat(70_000) });

  const result = await runProcess(['bash', '-s', '--', String(impd.port)], {
    stdin: ctx.script,
    env: ctx.env,
  });

  expect(result.stdout.toString()).toBe(`200\n${'x'.repeat(65_536)}`);
});

test('it prints 000 and no body when nothing answers on the port', async () => {
  const ctx = await setupTest();
  const result = await runProcess(['bash', '-s', '--', '1'], { stdin: ctx.script, env: ctx.env });

  expect(result).toStrictEqual({
    exitCode: 0,
    stdout: Buffer.from('000\n'),
    stderr: Buffer.from(''),
    timedOut: false,
  });
});

test('it keeps a proxy variable and a .curlrc off its request', async () => {
  const ctx = await setupTest();

  const impd = startStubImpd('imp_fixture_good');

  await writeFile(join(ctx.dir, '.curlrc'), 'proxy = "http://127.0.0.1:1"\n');

  const result = await runProcess(['bash', '-s', '--', String(impd.port)], {
    stdin: ctx.script,
    env: { ...ctx.env, http_proxy: 'http://127.0.0.1:1', ALL_PROXY: 'http://127.0.0.1:1' },
  });

  expect(result.stdout.toString()).toBe('200\n{"ready":true}');
});

test('its control: the same .curlrc and proxy variable send a plain curl off loopback', async () => {
  const ctx = await setupTest();

  const impd = startStubImpd('imp_fixture_good');

  await writeFile(join(ctx.dir, '.curlrc'), 'proxy = "http://127.0.0.1:1"\n');

  const result = await runProcess(
    ['curl', '-s', '-o', '/dev/null', '-w', '%{http_code}', `http://127.0.0.1:${impd.port}/health`],
    { env: { ...ctx.env, http_proxy: 'http://127.0.0.1:1', ALL_PROXY: 'http://127.0.0.1:1' } },
  );

  expect(result.stdout.toString()).toBe('000');
  expect(impd.requests).toStrictEqual([]);
});

import { expect, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runProcess } from '../run-process.ts';
import { startStubImpd } from '../test-utils/start-stub-impd.ts';

// The script runs as the host gets it, with real bash reading it on stdin, and real curl asks the
// impd stand-in on loopback
async function setupTest() {
  const dir = await mkdtemp(join(tmpdir(), 'check-atc-imp-token-'));

  onTestFinished(() => rm(dir, { recursive: true, force: true }));

  const script = await readFile(new URL('check-atc-imp-token.sh', import.meta.url));

  return { dir, script, env: { PATH: process.env['PATH'] ?? '/usr/bin:/bin', HOME: dir } };
}

const identity =
  '{"json":{"kind":"token","name":"atc-cloud","scope":"manage","imps":["harness-*"],"grantable":["glm"]}}';

test('it sends the saved token alone to impd’s whoami and prints the answer and its status', async () => {
  const ctx = await setupTest();

  const impd = startStubImpd('imp_fixture_good');

  await writeFile(join(ctx.dir, 'imp-token'), 'imp_fixture_good\n');

  const result = await runProcess(['bash', '-s', '--', ctx.dir, String(impd.port)], {
    stdin: ctx.script,
    env: ctx.env,
  });

  expect(result.exitCode).toBe(0);
  expect(result.stdout.toString()).toBe(`${identity}\n200`);
  expect(result.stderr.toString()).toBe('');

  expect(impd.requests).toStrictEqual([
    {
      method: 'POST',
      target: '/rpc/tokens/whoami',
      authorization: 'Bearer imp_fixture_good',
      body: '{"json":{}}',
    },
  ]);
});

test('it accepts a saved token without a trailing newline', async () => {
  const ctx = await setupTest();

  const impd = startStubImpd('imp_fixture_good');

  await writeFile(join(ctx.dir, 'imp-token'), 'imp_fixture_good');

  const result = await runProcess(['bash', '-s', '--', ctx.dir, String(impd.port)], {
    stdin: ctx.script,
    env: ctx.env,
  });

  expect(result.stdout.toString()).toBe(`${identity}\n200`);
});

test('it prints impd’s 401 for a stale saved token', async () => {
  const ctx = await setupTest();

  const impd = startStubImpd('imp_fixture_good');

  await writeFile(join(ctx.dir, 'imp-token'), 'imp_fixture_stale\n');

  const result = await runProcess(['bash', '-s', '--', ctx.dir, String(impd.port)], {
    stdin: ctx.script,
    env: ctx.env,
  });

  expect(result.exitCode).toBe(0);
  expect(result.stdout.toString()).toBe('{"error":"unauthorized"}\n401');
});

test.each([
  ['an empty file', ''],
  ['a second line', 'imp_fixture_good\nsecond\n'],
  ['a blank line after the token', 'imp_fixture_good\n\n'],
  ['a carriage return', 'imp_fixture_good\r\n'],
  ['a space', 'imp_fixture good\n'],
  ['a NUL byte', 'imp_fixture\0good\n'],
])(
  'it exits 121 without asking impd for a saved token with %s',
  async (_label: string, content: string) => {
    const ctx = await setupTest();

    const impd = startStubImpd('imp_fixture_good');

    await writeFile(join(ctx.dir, 'imp-token'), content);

    const result = await runProcess(['bash', '-s', '--', ctx.dir, String(impd.port)], {
      stdin: ctx.script,
      env: ctx.env,
    });

    expect(result.exitCode).toBe(121);
    expect(result.stdout.toString()).toBe('');
    expect(impd.requests).toStrictEqual([]);
  },
);

test.each([
  ['a missing file', false],
  ['a directory in its place', true],
])('it exits 120 without asking impd for %s', async (_label: string, directory: boolean) => {
  const ctx = await setupTest();

  const impd = startStubImpd('imp_fixture_good');

  if (directory) {
    await mkdir(join(ctx.dir, 'imp-token'));
  }

  const result = await runProcess(['bash', '-s', '--', ctx.dir, String(impd.port)], {
    stdin: ctx.script,
    env: ctx.env,
  });

  expect(result.exitCode).toBe(120);
  expect(impd.requests).toStrictEqual([]);
});

test('it exits with curl’s code when impd refuses the connection', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.dir, 'imp-token'), 'imp_fixture_good\n');

  // nothing listens on port 1
  const result = await runProcess(['bash', '-s', '--', ctx.dir, '1'], {
    stdin: ctx.script,
    env: ctx.env,
  });

  expect(result.exitCode).toBe(7);
  expect(result.stdout.toString()).toBe('\n000');

  // curl 8.5.0 (Ubuntu 24.04) and 8.22.0 word the refusal differently; both exit 7. The connect
  // time is masked, since it changes between runs.
  expect(result.stderr.toString().replace(/ after \d+ ms: /u, ' after N ms: ')).toBeOneOf([
    "curl: (7) Failed to connect to 127.0.0.1 port 1 after N ms: Couldn't connect to server\n",
    'curl: (7) Failed to connect to 127.0.0.1:1 after N ms: Could not connect to server\n',
  ]);
});

test('it keeps the request on loopback under a hostile curl config and proxy variables', async () => {
  const ctx = await setupTest();

  const impd = startStubImpd('imp_fixture_good');
  const proxy = startStubImpd('imp_fixture_good');
  const proxyURL = `http://127.0.0.1:${proxy.port}`;

  await writeFile(join(ctx.dir, 'imp-token'), 'imp_fixture_good\n');

  await writeFile(
    join(ctx.dir, '.curlrc'),
    `proxy = "${proxyURL}"\nheader = "Authorization: Bearer imp_fixture_curlrc"\n`,
  );

  const result = await runProcess(['bash', '-s', '--', ctx.dir, String(impd.port)], {
    stdin: ctx.script,
    env: {
      ...ctx.env,
      http_proxy: proxyURL,
      HTTP_PROXY: proxyURL,
      all_proxy: proxyURL,
      ALL_PROXY: proxyURL,
    },
  });

  expect(result.stdout.toString()).toBe(`${identity}\n200`);
  expect(proxy.requests).toStrictEqual([]);

  expect(impd.requests.map((request) => request.authorization)).toStrictEqual([
    'Bearer imp_fixture_good',
  ]);
});

test('it writes no trace under a curl config that asks for one', async () => {
  const ctx = await setupTest();

  const impd = startStubImpd('imp_fixture_good');

  await writeFile(join(ctx.dir, 'imp-token'), 'imp_fixture_good\n');
  await writeFile(join(ctx.dir, '.curlrc'), `trace-ascii = "${ctx.dir}/trace"\n`);

  await runProcess(['bash', '-s', '--', ctx.dir, String(impd.port)], {
    stdin: ctx.script,
    env: ctx.env,
  });

  const traced = await Bun.file(join(ctx.dir, 'trace')).exists();

  expect(traced).toBe(false);
});

test('it sends a plain curl through the same hostile config to the proxy, which the check above defeats', async () => {
  const ctx = await setupTest();

  const impd = startStubImpd('imp_fixture_good');
  const proxy = startStubImpd('imp_fixture_good');
  const proxyURL = `http://127.0.0.1:${proxy.port}`;

  await writeFile(
    join(ctx.dir, '.curlrc'),
    `proxy = "${proxyURL}"\ntrace-ascii = "${ctx.dir}/trace"\n`,
  );

  await runProcess(
    ['curl', '-sS', '--data', '{"json":{}}', `http://127.0.0.1:${impd.port}/rpc/tokens/whoami`],
    {
      env: { ...ctx.env, http_proxy: proxyURL },
    },
  );

  expect(proxy.requests.map((request) => request.target)).toStrictEqual([
    `http://127.0.0.1:${impd.port}/rpc/tokens/whoami`,
  ]);

  const traced = await Bun.file(join(ctx.dir, 'trace')).exists();

  expect(traced).toBe(true);
});

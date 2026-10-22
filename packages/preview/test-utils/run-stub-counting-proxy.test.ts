import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { http, passthrough } from 'msw';
import { z } from 'zod';
import { server as mockServer } from '../mocks/node.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'stub-counting-proxy-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  // the stub's port comes from the kernel, so every loopback port passes through
  mockServer.use(http.all(/^http:\/\/127\.0\.0\.1:\d+\//u, () => passthrough()));

  return { directory, stubPath: join(import.meta.dir, 'run-stub-counting-proxy.ts') };
}

test('it prints the proxy.started line with its port, then echoes each request', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.directory, 'proxy.json'),
    JSON.stringify({
      listen: { hostname: '127.0.0.1', port: 0 },
      store: join(ctx.directory, 'count.json'),
      limits: { dollars: 2 },
      routes: { 'pv-0a1b2c3d-7': {} },
    }),
  );

  const child = Bun.spawn([ctx.stubPath, '--config', join(ctx.directory, 'proxy.json')], {
    stdout: 'pipe',
  });

  onTestFinished(async () => {
    child.kill();

    await child.exited;
  });

  const reader = child.stdout.getReader();

  const first = await reader.read();

  const line = new TextDecoder().decode(first.value).split('\n')[0] ?? '';

  const started = z
    .object({ event: z.literal('proxy.started'), port: z.int() })
    .parse(JSON.parse(line));

  const response = await fetch(
    `http://127.0.0.1:${started.port}/pv-0a1b2c3d-7/v1/messages?beta=true`,
    {
      method: 'POST',
      body: '{"model":"model-small"}',
    },
  );

  const body: unknown = await response.json();

  expect(body).toStrictEqual({
    method: 'POST',
    path: '/pv-0a1b2c3d-7/v1/messages?beta=true',
    body: '{"model":"model-small"}',
    routes: ['pv-0a1b2c3d-7'],
    limit: 2,
  });
});

test('it exits when a request asks it to', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.directory, 'proxy.json'),
    JSON.stringify({
      listen: { hostname: '127.0.0.1', port: 0 },
      limits: { dollars: 2 },
      routes: { 'pv-0a1b2c3d-7': {} },
    }),
  );

  const child = Bun.spawn([ctx.stubPath, '--config', join(ctx.directory, 'proxy.json')], {
    stdout: 'pipe',
  });

  onTestFinished(() => {
    child.kill();
  });

  const first = await child.stdout.getReader().read();

  const line = new TextDecoder().decode(first.value).split('\n')[0] ?? '';
  const started = z.object({ port: z.int() }).parse(JSON.parse(line));

  await fetch(`http://127.0.0.1:${started.port}/exit`);

  const code = await child.exited;

  expect(code).toBe(0);
});

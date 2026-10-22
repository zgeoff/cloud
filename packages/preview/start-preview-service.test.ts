import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { http, passthrough } from 'msw';
import { createPreviewStore } from './create-preview-store.ts';
import { server as mockServer } from './mocks/node.ts';
import { startPreviewService } from './start-preview-service.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'preview-service-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  // the listeners and each proxy take loopback ports, so every loopback port passes through
  mockServer.use(http.all(/^http:\/\/127\.0\.0\.1:\d+\//u, () => passthrough()));

  return { directory, stubPath: join(import.meta.dir, 'test-utils', 'run-stub-counting-proxy.ts') };
}

test("it sends a preview's model call from its route listener to that preview's proxy", async () => {
  const ctx = await setupTest();

  const seed = createPreviewStore(join(ctx.directory, 'previews.sqlite'));

  seed.upsertHead({
    repo: 'acme/greenhouse',
    number: 7,
    imp: 'pv-0a1b2c3d-7',
    headSHA: 'c0ffee1',
  });

  seed.close();

  // the route listener needs a known port, so the test takes a free one from the kernel first
  const probe = Bun.listen({ hostname: '127.0.0.1', port: 0, socket: { data: () => {} } });
  const port = probe.port;

  probe.stop(true);

  const service = startPreviewService({
    settings: {
      baseURL: 'http://cloudhost.test:8417',
      repos: new Set(['acme/greenhouse']),
      slots: 1,
      idleMs: 1_800_000,
      impDomain: 'imps.example.test',
      impImage: 'pv-base',
      impMemoryMib: 2048,
      impGitHubSecret: null,
      impModelSecret: 'preview-model-counted',
      buildTimeoutMs: 600_000,
      healthTimeoutMs: 120_000,
      healthPollMs: 1000,
      contract: null,
    },
    linkListener: { hostname: '127.0.0.1', port: 0 },
    webhookListener: { hostname: '127.0.0.1', port: 0 },
    impdURL: 'http://127.0.0.1:1',
    databasePath: join(ctx.directory, 'previews.sqlite'),
    webhookSecret: 'whsec-example',
    githubToken: 'github-token-example',
    impdToken: 'imp_example.token',
    sweepIntervalMs: 3_600_000,
    spend: {
      listener: { hostname: '127.0.0.1', port },
      settings: {
        proxyPath: ctx.stubPath,
        directory: join(ctx.directory, 'spend'),
        upstream: 'https://models.example.test',
        model: 'model-small',
        prices: { input: 1, cache_write: 1.25, cache_write_1h: 2, cached_input: 0.1, output: 5 },
        limitDollars: 2,
        idleMs: 1_800_000,
      },
    },
  });

  onTestFinished(() => service.stop());

  const response = await fetch(`http://127.0.0.1:${String(port)}/pv-0a1b2c3d-7/v1/messages`, {
    method: 'POST',
    body: '{"model":"model-small"}',
  });

  const body: unknown = await response.json();

  expect(body).toStrictEqual({
    method: 'POST',
    path: '/pv-0a1b2c3d-7/v1/messages',
    body: '{"model":"model-small"}',
    routes: ['pv-0a1b2c3d-7'],
    limit: 2,
  });
});

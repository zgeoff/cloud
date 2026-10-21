import { expect, onTestFinished, test } from 'bun:test';
import { join } from 'node:path';
import { http, passthrough } from 'msw';
import { server } from './mocks/node.ts';
import { spawnPiped } from './spawn-piped.ts';
import { startKubectlProxy } from './start-kubectl-proxy.ts';

test('it gives the URL that the proxy serves on', async () => {
  const started = await startKubectlProxy({
    argv: ['bun', join(import.meta.dir, 'test-utils/run-stub-kubectl-proxy.ts'), 'serve'],
    timeoutMs: 10_000,
    spawn: spawnPiped,
  });

  if (!started.ok) {
    throw new Error(started.error);
  }

  onTestFinished(() => started.proxy.stop());

  server.use(http.get(`${started.proxy.url}/*`, () => passthrough()));

  const response = await fetch(`${started.proxy.url}/api/v1/namespaces`);
  const body = await response.text();

  expect(started.proxy.url).toMatch(/^http:\/\/127\.0\.0\.1:\d+$/u);
  expect(body).toBe('stub kubectl proxy');
});

test('it reports the error of a proxy that exits before it listens', async () => {
  const started = await startKubectlProxy({
    argv: [
      'bun',
      join(import.meta.dir, 'test-utils/run-stub-kubectl-proxy.ts'),
      'refuse',
      'error: open /missing/kubeconfig: no such file or directory',
    ],
    timeoutMs: 10_000,
    spawn: spawnPiped,
  });

  expect(started).toStrictEqual({
    ok: false,
    error:
      'kubectl proxy exited before it listened: error: open /missing/kubeconfig: no such file or directory',
  });
});

test('it reports a proxy that prints no address in time', async () => {
  const started = await startKubectlProxy({
    argv: ['bun', join(import.meta.dir, 'test-utils/run-stub-kubectl-proxy.ts'), 'quiet'],
    timeoutMs: 500,
    spawn: spawnPiped,
  });

  expect(started).toStrictEqual({
    ok: false,
    error: 'kubectl proxy printed no address within 500 ms',
  });
});

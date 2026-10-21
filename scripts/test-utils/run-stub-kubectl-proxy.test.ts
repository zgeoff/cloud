import { expect, onTestFinished, test } from 'bun:test';
import { join } from 'node:path';
import { http, passthrough } from 'msw';
import { server } from '../mocks/node.ts';

test('it prints the serving line with the port it listens on', async () => {
  const subprocess = Bun.spawn(
    ['bun', join(import.meta.dir, 'run-stub-kubectl-proxy.ts'), 'serve'],
    {
      stdout: 'pipe',
      stderr: 'pipe',
    },
  );

  onTestFinished(() => {
    subprocess.kill();
  });

  const reader = subprocess.stdout.getReader();

  const chunk = await reader.read();

  const line = new TextDecoder().decode(chunk.value);

  const port = /^Starting to serve on 127\.0\.0\.1:(?<port>\d+)\n$/u.exec(line)?.groups?.['port'];

  server.use(http.get(`http://127.0.0.1:${port ?? '1'}/*`, () => passthrough()));

  const response = await fetch(`http://127.0.0.1:${port ?? '1'}/api/v1/namespaces`);
  const body = await response.text();

  expect(body).toBe('stub kubectl proxy');
});

test('it prints nothing while it runs quiet, until it is stopped', async () => {
  const subprocess = Bun.spawn(
    ['bun', join(import.meta.dir, 'run-stub-kubectl-proxy.ts'), 'quiet'],
    {
      stdout: 'pipe',
      stderr: 'pipe',
    },
  );

  subprocess.kill();

  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(subprocess.stdout).text(),
    new Response(subprocess.stderr).text(),
    subprocess.exited,
  ]);

  expect({ stdout, stderr, exitCode, signal: subprocess.signalCode }).toStrictEqual({
    stdout: '',
    stderr: '',
    exitCode: 143,
    signal: 'SIGTERM',
  });
});

test('it prints the error and exits 1 when it refuses', async () => {
  const subprocess = Bun.spawn(
    [
      'bun',
      join(import.meta.dir, 'run-stub-kubectl-proxy.ts'),
      'refuse',
      'error: open /missing/kubeconfig: no such file or directory',
    ],
    { stdout: 'pipe', stderr: 'pipe' },
  );

  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(subprocess.stdout).text(),
    new Response(subprocess.stderr).text(),
    subprocess.exited,
  ]);

  expect({ stdout, stderr, exitCode }).toStrictEqual({
    stdout: '',
    stderr: 'error: open /missing/kubeconfig: no such file or directory\n',
    exitCode: 1,
  });
});

test('it exits 97 on an argument it does not model', async () => {
  const subprocess = Bun.spawn(
    ['bun', join(import.meta.dir, 'run-stub-kubectl-proxy.ts'), 'version'],
    { stdout: 'pipe', stderr: 'pipe' },
  );

  const [stderr, exitCode] = await Promise.all([
    new Response(subprocess.stderr).text(),
    subprocess.exited,
  ]);

  expect({ stderr, exitCode }).toStrictEqual({ stderr: 'unexpected: ["version"]\n', exitCode: 97 });
});

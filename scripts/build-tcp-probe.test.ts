import { expect, onTestFinished, test } from 'bun:test';
import { buildTCPProbe } from './build-tcp-probe.ts';

test('it prints status 0 for a port with a listener', async () => {
  const listener = Bun.listen({
    hostname: '127.0.0.1',
    port: 0,
    socket: { data: () => {} },
  });

  onTestFinished(() => listener.stop(true));

  const proc = Bun.spawn(
    ['bash', '-c', buildTCPProbe({ host: '127.0.0.1', port: listener.port })],
    { env: { PATH: '/usr/bin:/bin' }, stdout: 'pipe' },
  );

  const stdout = await new Response(proc.stdout).text();

  expect(stdout).toBe('probe-exit:0\n');
});

test('it prints status 1 for a port that refuses the connection', async () => {
  const proc = Bun.spawn(['bash', '-c', buildTCPProbe({ host: '127.0.0.1', port: 1 })], {
    env: { PATH: '/usr/bin:/bin' },
    stdout: 'pipe',
  });

  const stdout = await new Response(proc.stdout).text();

  expect(stdout).toBe('probe-exit:1\n');
});

test('it writes the address and the port into the probe', () => {
  expect(buildTCPProbe({ host: 'fd7a:115c:a1e0::5', port: 443 })).toBe(
    "timeout 5 bash -c 'exec 3<>/dev/tcp/fd7a:115c:a1e0::5/443' 2>/dev/null; echo probe-exit:$?",
  );
});

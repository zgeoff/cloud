import { expect, test } from 'bun:test';
import { buildTCPProbe } from '../build-tcp-probe.ts';
import { toShellArg } from '../to-shell-arg.ts';
import { buildStubGeoffcloud } from './build-stub-geoffcloud.ts';

test('it prints impd’s address once for each socket type, address first, as getent ahosts does', async () => {
  const host = buildStubGeoffcloud({
    manifest:
      '{"fetch":"ghcr.io/zgeoff/nixie-fetch:0.3.0@sha256:9c4e2a71b0d35f68e1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708"}',
    impdAddresses: ['100.88.1.2'],
    nodeAddresses: ['104.250.100.18', '2401:a4a0:4:17f::1'],
    podAddress: '10.42.0.17',
    serviceAddress: '10.43.12.9',
    hostReaches: ['10.42.0.17:8080'],
    sandboxReaches: ['1.1.1.1:443'],
    page: '200 true\n',
    createExitCode: 0,
  });

  const result = await host.runRemote('getent ahosts imps.geoff.cloud');

  expect(result).toStrictEqual({
    exitCode: 0,
    stdout: '100.88.1.2 STREAM imps.geoff.cloud\n100.88.1.2 DGRAM',
    stderr: '',
  });
});

test('it connects the host’s probe only to an address the scenario lets the host reach', async () => {
  const host = buildStubGeoffcloud({
    manifest:
      '{"fetch":"ghcr.io/zgeoff/nixie-fetch:0.3.0@sha256:9c4e2a71b0d35f68e1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708"}',
    impdAddresses: ['100.88.1.2'],
    nodeAddresses: ['104.250.100.18', '2401:a4a0:4:17f::1'],
    podAddress: '10.42.0.17',
    serviceAddress: '10.43.12.9',
    hostReaches: ['10.42.0.17:8080'],
    sandboxReaches: ['1.1.1.1:443'],
    page: '200 true\n',
    createExitCode: 0,
  });

  const reached = await host.runRemote(buildTCPProbe({ host: '10.42.0.17', port: 8080 }));
  const dropped = await host.runRemote(buildTCPProbe({ host: '10.43.12.9', port: 8080 }));

  expect(reached.stdout).toBe('probe-exit:0\n');
  expect(dropped.stdout).toBe('probe-exit:124\n');
});

test('it answers a sandbox’s probe from the sandbox’s reach once imp new has created it', async () => {
  const host = buildStubGeoffcloud({
    manifest:
      '{"fetch":"ghcr.io/zgeoff/nixie-fetch:0.3.0@sha256:9c4e2a71b0d35f68e1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708"}',
    impdAddresses: ['100.88.1.2'],
    nodeAddresses: ['104.250.100.18', '2401:a4a0:4:17f::1'],
    podAddress: '10.42.0.17',
    serviceAddress: '10.43.12.9',
    hostReaches: ['10.42.0.17:8080'],
    sandboxReaches: ['1.1.1.1:443'],
    page: '200 true\n',
    createExitCode: 0,
  });

  const created = await host.runRemote(
    'docker exec imp-host imp new fetch-check-1a2b3c4d --image nixie-fetch-9c4e2a71b0d3 --policy public',
  );

  const probe = await host.runRemote(
    `docker exec imp-host imp exec fetch-check-1a2b3c4d -- bash -c ${toShellArg(buildTCPProbe({ host: '1.1.1.1', port: 443 }))}`,
  );

  expect(created.exitCode).toBe(0);
  expect(probe.stdout).toBe('probe-exit:0\n');
  expect(host.sandboxes).toStrictEqual(new Set(['fetch-check-1a2b3c4d']));
});

test('it refuses imp exec and imp rm on a sandbox that does not exist, as imp does', async () => {
  const host = buildStubGeoffcloud({
    manifest:
      '{"fetch":"ghcr.io/zgeoff/nixie-fetch:0.3.0@sha256:9c4e2a71b0d35f68e1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708"}',
    impdAddresses: ['100.88.1.2'],
    nodeAddresses: ['104.250.100.18', '2401:a4a0:4:17f::1'],
    podAddress: '10.42.0.17',
    serviceAddress: '10.43.12.9',
    hostReaches: ['10.42.0.17:8080'],
    sandboxReaches: ['1.1.1.1:443'],
    page: '200 true\n',
    createExitCode: 0,
  });

  const removed = await host.runRemote('docker exec imp-host imp rm fetch-check-1a2b3c4d');

  expect(removed).toStrictEqual({
    exitCode: 1,
    stdout: '',
    stderr: 'imp: no imp named fetch-check-1a2b3c4d\n',
  });
});

test('it refuses a sandbox that is not public on a nixie fetch image', async () => {
  const host = buildStubGeoffcloud({
    manifest:
      '{"fetch":"ghcr.io/zgeoff/nixie-fetch:0.3.0@sha256:9c4e2a71b0d35f68e1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708"}',
    impdAddresses: ['100.88.1.2'],
    nodeAddresses: ['104.250.100.18', '2401:a4a0:4:17f::1'],
    podAddress: '10.42.0.17',
    serviceAddress: '10.43.12.9',
    hostReaches: ['10.42.0.17:8080'],
    sandboxReaches: ['1.1.1.1:443'],
    page: '200 true\n',
    createExitCode: 0,
  });

  const created = await host.runRemote(
    'docker exec imp-host imp new fetch-check-1a2b3c4d --image nixie-fetch-9c4e2a71b0d3',
  );

  expect(created.exitCode).toBe(97);
  expect(host.sandboxes).toBeEmpty();
});

test('it answers a command it does not model with exit 97', async () => {
  const host = buildStubGeoffcloud({
    manifest:
      '{"fetch":"ghcr.io/zgeoff/nixie-fetch:0.3.0@sha256:9c4e2a71b0d35f68e1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708"}',
    impdAddresses: ['100.88.1.2'],
    nodeAddresses: ['104.250.100.18', '2401:a4a0:4:17f::1'],
    podAddress: '10.42.0.17',
    serviceAddress: '10.43.12.9',
    hostReaches: ['10.42.0.17:8080'],
    sandboxReaches: ['1.1.1.1:443'],
    page: '200 true\n',
    createExitCode: 0,
  });

  const result = await host.runRemote('rm -rf /var/lib/rancher');

  expect(result).toStrictEqual({
    exitCode: 97,
    stdout: '',
    stderr: 'unexpected: rm -rf /var/lib/rancher',
  });
});

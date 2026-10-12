// each test states its whole scenario and output inline, so its body is long
/* oxlint-disable max-lines-per-function */
import { expect, mock, test } from 'bun:test';
import { checkNixieFetchSandbox } from './check-nixie-fetch-sandbox.ts';
import { buildStubGeoffcloud } from './test-utils/build-stub-geoffcloud.ts';

test('it reads a public page from the sandbox, finds every internal address blocked, and removes the sandbox', async () => {
  const host = buildStubGeoffcloud({
    manifest:
      '{"fetch":"ghcr.io/zgeoff/nixie-fetch:0.3.0@sha256:9c4e2a71b0d35f68e1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708"}',
    impdAddresses: ['100.88.1.2'],
    nodeAddresses: ['104.250.100.18'],
    podAddress: '10.42.0.17',
    serviceAddress: '10.43.12.9',
    hostReaches: [
      '100.88.1.2:443',
      '104.250.100.18:10250',
      '10.42.0.17:8080',
      '10.43.12.9:8080',
      '100.69.47.33:443',
    ],
    sandboxReaches: [],
    page: '200 true\n',
    createExitCode: 0,
  });

  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  const exitCode = await checkNixieFetchSandbox({
    args: ['100.69.47.33:443'],
    sandboxName: 'fetch-check-1a2b3c4d',
    runRemote: host.runRemote,
    printOut,
    printErr,
  });

  expect(exitCode).toBe(0);
  expect(printErr).not.toHaveBeenCalled();
  expect(host.sandboxes).toBeEmpty();

  expect(
    host.commands.filter((command) => command.startsWith('docker exec imp-host imp new')),
  ).toStrictEqual([
    'docker exec imp-host imp new fetch-check-1a2b3c4d --image nixie-fetch-9c4e2a71b0d3 --policy public',
  ]);

  expect(printOut.mock.calls).toStrictEqual([
    ['fetch image: nixie-fetch-9c4e2a71b0d3\n'],
    ['from the host: impd 100.88.1.2:443 connected\n'],
    ['from the host: node 104.250.100.18:10250 connected\n'],
    ['from the host: pod 10.42.0.17:8080 connected\n'],
    ['from the host: service 10.43.12.9:8080 connected\n'],
    ['from the host: tailnet 100.69.47.33:443 connected\n'],
    ['created sandbox fetch-check-1a2b3c4d on nixie-fetch-9c4e2a71b0d3, policy public\n'],
    ['public page: https://example.com/ answered 200 true\n'],
    ['from the sandbox: impd 100.88.1.2:443 blocked (exit 124)\n'],
    ['from the sandbox: node 104.250.100.18:10250 blocked (exit 124)\n'],
    ['from the sandbox: pod 10.42.0.17:8080 blocked (exit 124)\n'],
    ['from the sandbox: service 10.43.12.9:8080 blocked (exit 124)\n'],
    ['from the sandbox: tailnet 100.69.47.33:443 blocked (exit 124)\n'],
    ['removed sandbox fetch-check-1a2b3c4d\n'],
    ['fetch sandbox check passed\n'],
  ]);
});

test('it fails when the sandbox reaches an internal address, and still removes the sandbox', async () => {
  const host = buildStubGeoffcloud({
    manifest:
      '{"fetch":"ghcr.io/zgeoff/nixie-fetch:0.3.0@sha256:9c4e2a71b0d35f68e1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708"}',
    impdAddresses: ['100.88.1.2'],
    nodeAddresses: ['104.250.100.18'],
    podAddress: '10.42.0.17',
    serviceAddress: '10.43.12.9',
    hostReaches: [
      '100.88.1.2:443',
      '104.250.100.18:10250',
      '10.42.0.17:8080',
      '10.43.12.9:8080',
      '100.69.47.33:443',
    ],
    sandboxReaches: ['10.43.12.9:8080'],
    page: '200 true\n',
    createExitCode: 0,
  });

  const printErr = mock<(text: string) => void>();

  const exitCode = await checkNixieFetchSandbox({
    args: ['100.69.47.33:443'],
    sandboxName: 'fetch-check-1a2b3c4d',
    runRemote: host.runRemote,
    printOut: mock<(text: string) => void>(),
    printErr,
  });

  expect(exitCode).toBe(1);
  expect(host.sandboxes).toBeEmpty();

  expect(printErr.mock.calls).toStrictEqual([
    ["check-nixie-fetch-sandbox: the sandbox's probe of service 10.43.12.9:8080 connected\n"],
  ]);
});

test('it fails when a sandbox probe exits with a status that proves no block, such as a missing timeout', async () => {
  const host = buildStubGeoffcloud({
    manifest:
      '{"fetch":"ghcr.io/zgeoff/nixie-fetch:0.3.0@sha256:9c4e2a71b0d35f68e1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708"}',
    impdAddresses: ['100.88.1.2'],
    nodeAddresses: ['104.250.100.18'],
    podAddress: '10.42.0.17',
    serviceAddress: '10.43.12.9',
    hostReaches: [
      '100.88.1.2:443',
      '104.250.100.18:10250',
      '10.42.0.17:8080',
      '10.43.12.9:8080',
      '100.69.47.33:443',
    ],
    sandboxReaches: [],
    page: '200 true\n',
    createExitCode: 0,
  });

  const printErr = mock<(text: string) => void>();

  const exitCode = await checkNixieFetchSandbox({
    args: ['100.69.47.33:443'],
    sandboxName: 'fetch-check-1a2b3c4d',
    runRemote: async (command: string) => {
      const result = await host.runRemote(command);

      return command.includes('imp exec')
        ? { ...result, stdout: result.stdout.replace('probe-exit:124', 'probe-exit:127') }
        : result;
    },
    printOut: mock<(text: string) => void>(),
    printErr,
  });

  expect(exitCode).toBe(1);
  expect(host.sandboxes).toBeEmpty();

  expect(printErr.mock.calls).toStrictEqual([
    [
      "check-nixie-fetch-sandbox: the sandbox's probe of impd 100.88.1.2:443 probe failed (exit 127)\n",
    ],
    [
      "check-nixie-fetch-sandbox: the sandbox's probe of node 104.250.100.18:10250 probe failed (exit 127)\n",
    ],
    [
      "check-nixie-fetch-sandbox: the sandbox's probe of pod 10.42.0.17:8080 probe failed (exit 127)\n",
    ],
    [
      "check-nixie-fetch-sandbox: the sandbox's probe of service 10.43.12.9:8080 probe failed (exit 127)\n",
    ],
    [
      "check-nixie-fetch-sandbox: the sandbox's probe of tailnet 100.69.47.33:443 probe failed (exit 127)\n",
    ],
  ]);
});

test('it fails when the sandbox cannot read the public page', async () => {
  const host = buildStubGeoffcloud({
    manifest:
      '{"fetch":"ghcr.io/zgeoff/nixie-fetch:0.3.0@sha256:9c4e2a71b0d35f68e1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708"}',
    impdAddresses: ['100.88.1.2'],
    nodeAddresses: ['104.250.100.18'],
    podAddress: '10.42.0.17',
    serviceAddress: '10.43.12.9',
    hostReaches: [
      '100.88.1.2:443',
      '104.250.100.18:10250',
      '10.42.0.17:8080',
      '10.43.12.9:8080',
      '100.69.47.33:443',
    ],
    sandboxReaches: [],
    page: '',
    createExitCode: 0,
  });

  const printErr = mock<(text: string) => void>();

  const exitCode = await checkNixieFetchSandbox({
    args: ['100.69.47.33:443'],
    sandboxName: 'fetch-check-1a2b3c4d',
    runRemote: host.runRemote,
    printOut: mock<(text: string) => void>(),
    printErr,
  });

  expect(exitCode).toBe(1);
  expect(host.sandboxes).toBeEmpty();

  expect(printErr.mock.calls).toStrictEqual([
    ['check-nixie-fetch-sandbox: the sandbox did not read https://example.com/: \n'],
  ]);
});

test('it removes the sandbox when a command fails mid-check', async () => {
  const host = buildStubGeoffcloud({
    manifest:
      '{"fetch":"ghcr.io/zgeoff/nixie-fetch:0.3.0@sha256:9c4e2a71b0d35f68e1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708"}',
    impdAddresses: ['100.88.1.2'],
    nodeAddresses: ['104.250.100.18'],
    podAddress: '10.42.0.17',
    serviceAddress: '10.43.12.9',
    hostReaches: [
      '100.88.1.2:443',
      '104.250.100.18:10250',
      '10.42.0.17:8080',
      '10.43.12.9:8080',
      '100.69.47.33:443',
    ],
    sandboxReaches: [],
    page: '200 true\n',
    createExitCode: 0,
  });

  const printErr = mock<(text: string) => void>();

  const exitCode = await checkNixieFetchSandbox({
    args: ['100.69.47.33:443'],
    sandboxName: 'fetch-check-1a2b3c4d',
    runRemote: (command: string) =>
      command.includes('/usr/local/bin/bun')
        ? Promise.reject(new Error('ssh: connection closed'))
        : host.runRemote(command),
    printOut: mock<(text: string) => void>(),
    printErr,
  });

  expect(exitCode).toBe(1);
  expect(host.sandboxes).toBeEmpty();

  expect(printErr.mock.calls).toStrictEqual([
    ['check-nixie-fetch-sandbox: the check stopped: Error: ssh: connection closed\n'],
  ]);
});

test('it creates no sandbox when a target does not answer the host', async () => {
  const host = buildStubGeoffcloud({
    manifest:
      '{"fetch":"ghcr.io/zgeoff/nixie-fetch:0.3.0@sha256:9c4e2a71b0d35f68e1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708"}',
    impdAddresses: ['100.88.1.2'],
    nodeAddresses: ['104.250.100.18'],
    podAddress: '10.42.0.17',
    serviceAddress: '10.43.12.9',
    hostReaches: ['100.88.1.2:443', '104.250.100.18:10250', '10.42.0.17:8080', '10.43.12.9:8080'],
    sandboxReaches: [],
    page: '200 true\n',
    createExitCode: 0,
  });

  const printErr = mock<(text: string) => void>();

  const exitCode = await checkNixieFetchSandbox({
    args: ['100.69.47.33:443'],
    sandboxName: 'fetch-check-1a2b3c4d',
    runRemote: host.runRemote,
    printOut: mock<(text: string) => void>(),
    printErr,
  });

  expect(exitCode).toBe(1);
  expect(host.commands.filter((command) => command.startsWith('docker'))).toStrictEqual([]);

  expect(printErr.mock.calls).toStrictEqual([
    [
      'check-nixie-fetch-sandbox: a target does not answer from the host, so a refusal from the sandbox would prove nothing\n',
    ],
  ]);
});

test('it stops when impd cannot create the sandbox, and names it for imp ls', async () => {
  const host = buildStubGeoffcloud({
    manifest:
      '{"fetch":"ghcr.io/zgeoff/nixie-fetch:0.3.0@sha256:9c4e2a71b0d35f68e1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708"}',
    impdAddresses: ['100.88.1.2'],
    nodeAddresses: ['104.250.100.18'],
    podAddress: '10.42.0.17',
    serviceAddress: '10.43.12.9',
    hostReaches: [
      '100.88.1.2:443',
      '104.250.100.18:10250',
      '10.42.0.17:8080',
      '10.43.12.9:8080',
      '100.69.47.33:443',
    ],
    sandboxReaches: [],
    page: '200 true\n',
    createExitCode: 1,
  });

  const printErr = mock<(text: string) => void>();

  const exitCode = await checkNixieFetchSandbox({
    args: ['100.69.47.33:443'],
    sandboxName: 'fetch-check-1a2b3c4d',
    runRemote: host.runRemote,
    printOut: mock<(text: string) => void>(),
    printErr,
  });

  expect(exitCode).toBe(1);

  expect(host.commands.filter((command) => command.startsWith('docker'))).toStrictEqual([
    'docker exec imp-host imp new fetch-check-1a2b3c4d --image nixie-fetch-9c4e2a71b0d3 --policy public',
  ]);

  expect(printErr.mock.calls).toStrictEqual([
    [
      'check-nixie-fetch-sandbox: cannot create sandbox fetch-check-1a2b3c4d: imp: no image by that name; look for it with imp ls\n',
    ],
  ]);
});

test('it probes the tailnet address given as its argument', async () => {
  const host = buildStubGeoffcloud({
    manifest:
      '{"fetch":"ghcr.io/zgeoff/nixie-fetch:0.3.0@sha256:9c4e2a71b0d35f68e1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708"}',
    impdAddresses: ['100.88.1.2'],
    nodeAddresses: ['104.250.100.18'],
    podAddress: '10.42.0.17',
    serviceAddress: '10.43.12.9',
    hostReaches: [
      '100.88.1.2:443',
      '104.250.100.18:10250',
      '10.42.0.17:8080',
      '10.43.12.9:8080',
      '100.71.3.4:22',
    ],
    sandboxReaches: [],
    page: '200 true\n',
    createExitCode: 0,
  });

  const printOut = mock<(text: string) => void>();

  const exitCode = await checkNixieFetchSandbox({
    args: ['100.71.3.4:22'],
    sandboxName: 'fetch-check-1a2b3c4d',
    runRemote: host.runRemote,
    printOut,
    printErr: mock<(text: string) => void>(),
  });

  expect(exitCode).toBe(0);

  expect(printOut.mock.calls).toPartiallyContain([
    'from the sandbox: tailnet 100.71.3.4:22 blocked (exit 124)\n',
  ]);
});

test('it rejects an argument that is not an address and a port, and never reaches the host', async () => {
  const runRemote =
    mock<(command: string) => Promise<{ exitCode: number; stdout: string; stderr: string }>>();

  const printErr = mock<(text: string) => void>();

  const exitCode = await checkNixieFetchSandbox({
    args: ['geoffcloud'],
    sandboxName: 'fetch-check-1a2b3c4d',
    runRemote,
    printOut: mock<(text: string) => void>(),
    printErr,
  });

  expect(exitCode).toBe(2);
  expect(runRemote).not.toHaveBeenCalled();

  expect(printErr.mock.calls).toStrictEqual([
    [
      'check-nixie-fetch-sandbox: give one tailnet address and port, such as 100.69.47.33:443\nusage: bun run nixie:check-sandbox <tailnet address>:<port>\n',
    ],
  ]);
});

test('it refuses to run with no tailnet target, and never reaches the host', async () => {
  const runRemote =
    mock<(command: string) => Promise<{ exitCode: number; stdout: string; stderr: string }>>();

  const printErr = mock<(text: string) => void>();

  const exitCode = await checkNixieFetchSandbox({
    args: [],
    sandboxName: 'fetch-check-1a2b3c4d',
    runRemote,
    printOut: mock<(text: string) => void>(),
    printErr,
  });

  expect(exitCode).toBe(2);
  expect(runRemote).not.toHaveBeenCalled();

  expect(printErr.mock.calls).toStrictEqual([
    [
      'check-nixie-fetch-sandbox: give a tailnet address and port to probe, such as 100.69.47.33:443\nusage: bun run nixie:check-sandbox <tailnet address>:<port>\n',
    ],
  ]);
});

test('it refuses a tailnet target on port 53, and never reaches the host', async () => {
  const runRemote =
    mock<(command: string) => Promise<{ exitCode: number; stdout: string; stderr: string }>>();

  const printErr = mock<(text: string) => void>();

  const exitCode = await checkNixieFetchSandbox({
    args: ['100.100.100.100:53'],
    sandboxName: 'fetch-check-1a2b3c4d',
    runRemote,
    printOut: mock<(text: string) => void>(),
    printErr,
  });

  expect(exitCode).toBe(2);
  expect(runRemote).not.toHaveBeenCalled();

  expect(printErr.mock.calls).toStrictEqual([
    [
      "check-nixie-fetch-sandbox: cannot probe 100.100.100.100:53: imp redirects a public sandbox's DNS connections to its own DNS proxy, so a probe of port 53 can connect even when the sandbox is isolated; pick a tailnet port that is not 53, such as 100.69.47.33:443\nusage: bun run nixie:check-sandbox <tailnet address>:<port>\n",
    ],
  ]);
});

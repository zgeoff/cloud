import { expect, mock, test } from 'bun:test';
import { loadSandboxTargets } from './load-sandbox-targets.ts';

test('it targets impd on 443, each node on the kubelet port, and nixie’s pod and Service on 8080', async () => {
  const answers: Record<string, string> = {
    'getent ahosts imps.geoff.cloud':
      '100.88.1.2      STREAM imps.geoff.cloud\n100.88.1.2      DGRAM  \n100.88.1.2      RAW    \n',
    [`k3s kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address} {.items[*].status.addresses[?(@.type=="ExternalIP")].address}'`]:
      '104.250.100.18 2401:a4a0:4:17f::1',
    'k3s kubectl -n nixie get pod nixie-0 -o jsonpath={.status.podIP}': '10.42.0.17',
    'k3s kubectl -n nixie get service nixie -o jsonpath={.spec.clusterIP}': '10.43.12.9',
  };

  const runRemote = mock((command: string) => {
    const result =
      command in answers
        ? { exitCode: 0, stdout: answers[command] ?? '', stderr: '' }
        : { exitCode: 97, stdout: '', stderr: `unexpected: ${command}` };

    return Promise.resolve(result);
  });

  const result = await loadSandboxTargets(runRemote, { host: '100.100.100.100', port: 53 });

  expect(result).toStrictEqual({
    ok: true,
    targets: [
      { role: 'impd', host: '100.88.1.2', port: 443 },
      { role: 'node', host: '104.250.100.18', port: 10_250 },
      { role: 'node', host: '2401:a4a0:4:17f::1', port: 10_250 },
      { role: 'pod', host: '10.42.0.17', port: 8080 },
      { role: 'service', host: '10.43.12.9', port: 8080 },
      { role: 'tailnet', host: '100.100.100.100', port: 53 },
    ],
  });
});

test('it reports the stderr of a read that fails', async () => {
  const runRemote = mock((command: string) => {
    const result = command.includes('pod nixie-0')
      ? {
          exitCode: 1,
          stdout: '',
          stderr: 'Error from server (NotFound): pods "nixie-0" not found\n',
        }
      : { exitCode: 0, stdout: '10.42.0.17', stderr: '' };

    return Promise.resolve(result);
  });

  const result = await loadSandboxTargets(runRemote, { host: '100.100.100.100', port: 53 });

  expect(result).toStrictEqual({
    ok: false,
    error:
      'cannot read the addresses (exit 1): Error from server (NotFound): pods "nixie-0" not found',
  });
});

test('it refuses a role with no address, so no target goes unchecked', async () => {
  const runRemote = mock((command: string) =>
    Promise.resolve({
      exitCode: 0,
      stdout: command.includes('service') ? '' : '10.42.0.17',
      stderr: '',
    }),
  );

  const result = await loadSandboxTargets(runRemote, { host: '100.100.100.100', port: 53 });

  expect(result).toStrictEqual({ ok: false, error: 'found no address for: service' });
});

test('it drops every word that is not an IP address before it reaches a command line', async () => {
  const runRemote = mock((command: string) =>
    Promise.resolve({
      exitCode: 0,
      stdout: command.includes('nodes') ? '104.250.100.18 $(reboot) ;rm' : '10.42.0.17',
      stderr: '',
    }),
  );

  const result = await loadSandboxTargets(runRemote, { host: '100.100.100.100', port: 53 });

  expect(result).toMatchObject({
    ok: true,
    targets: expect.toPartiallyContain({ role: 'node', host: '104.250.100.18' }),
  });

  expect(JSON.stringify(result)).not.toInclude('reboot');
});

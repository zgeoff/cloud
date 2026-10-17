import { expect, test } from 'bun:test';
import { runProcess } from '../run-process.ts';
import { toShellArg } from '../to-shell-arg.ts';
import { buildStubReadinessHost } from './build-stub-readiness-host.ts';
import { buildStubRunner } from './build-stub-runner.ts';

test('it reads the quoted command line as the remote bash splits it', async () => {
  const words = ['curl', '-H', 'Host: atc.geoff.cloud', '-w', '%{http_code}', "it's"];
  const command = words.map((word) => toShellArg(word)).join(' ');

  const result = await runProcess(['bash', '-c', `printf '%s\\n' ${command}`], {
    env: { PATH: process.env['PATH'] },
  });

  expect(result.stdout.toString()).toBe(`${words.join('\n')}\n`);
});

test('it answers the in-cluster probe, whose Host header holds a space, as one word', async () => {
  const stub = buildStubRunner(
    buildStubReadinessHost({
      destination: 'root@geoffcloud',
      nodeLine: '',
      availableMiB: 2048,
      namespaces: [],
      storageClasses: [],
      deployments: {},
      isDaemonActive: false,
      impdHealth: '',
      probeCode: '200',
    }),
  );

  const probe = [
    'k3s',
    'kubectl',
    '-n',
    'atc',
    'run',
    'readiness-probe',
    '--rm',
    '-i',
    '--restart=Never',
    '--quiet',
    '--image=curlimages/curl:8.16.0',
    '--',
    'curl',
    '-s',
    '-o',
    '/dev/null',
    '-w',
    '%{http_code}',
    '-H',
    'Host: atc.geoff.cloud',
    'http://atc-gateway.atc.svc.cluster.local:8414/.well-known/oauth-protected-resource/mcp',
  ];

  const result = await stub.run([
    'ssh',
    '-o',
    'BatchMode=yes',
    '-o',
    'ConnectTimeout=15',
    'root@geoffcloud',
    probe.map((word) => toShellArg(word)).join(' '),
  ]);

  expect(result.stdout.toString()).toBe('200');
});

test('it answers the node, memory, object, daemon and impd checks from the scenario', async () => {
  const stub = buildStubRunner(
    buildStubReadinessHost({
      destination: 'root@geoffcloud',
      nodeLine: 'geoffcloud   Ready    control-plane,master   40d   v1.33.4+k3s1',
      availableMiB: 2048,
      namespaces: ['atc'],
      storageClasses: [],
      deployments: { 'ingress/cloudflared': 1 },
      isDaemonActive: true,
      impdHealth: '200 1',
      probeCode: '',
    }),
  );

  const ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', 'root@geoffcloud'];

  const node = await stub.run([...ssh, "'k3s' 'kubectl' 'get' 'nodes' '--no-headers'"]);
  const free = await stub.run([...ssh, "'free' '-m'"]);
  const namespace = await stub.run([...ssh, "'k3s' 'kubectl' 'get' 'namespace' 'atc'"]);

  const storage = await stub.run([
    ...ssh,
    "'k3s' 'kubectl' 'get' 'storageclass' 'local-path-retain'",
  ]);

  const ready = await stub.run([
    ...ssh,
    "'k3s' 'kubectl' '-n' 'ingress' 'get' 'deploy' 'cloudflared' '-o' 'jsonpath={.status.readyReplicas}'",
  ]);

  const daemon = await stub.run([...ssh, "'systemctl' 'is-active' '--quiet' 'atc-daemon'"]);
  const impd = await stub.run([...ssh, "'bash' '-s' '--' '7070'"]);

  expect(node.stdout.toString()).toBe(
    'geoffcloud   Ready    control-plane,master   40d   v1.33.4+k3s1\n',
  );

  expect(free.stdout.toString()).toBe(
    '               total        used        free      shared  buff/cache   available\n' +
      'Mem:            3915        1234         567          12        2113        2048\n' +
      'Swap:              0           0           0\n',
  );

  expect(namespace.exitCode).toBe(0);

  expect(storage).toStrictEqual({
    exitCode: 1,
    stdout: Buffer.from(''),
    stderr: Buffer.from(
      'Error from server (NotFound): storageclasses.storage.k8s.io "local-path-retain" not found\n',
    ),
    timedOut: false,
  });

  expect(ready.stdout.toString()).toBe('1');
  expect(daemon.exitCode).toBe(0);
  expect(impd.stdout.toString()).toBe('200 1\n');
});

test('it answers an inactive daemon with systemctl’s exit 3', async () => {
  const stub = buildStubRunner(
    buildStubReadinessHost({
      destination: 'root@geoffcloud',
      nodeLine: '',
      availableMiB: 0,
      namespaces: [],
      storageClasses: [],
      deployments: {},
      isDaemonActive: false,
      impdHealth: '',
      probeCode: '',
    }),
  );

  const result = await stub.run([
    'ssh',
    '-o',
    'BatchMode=yes',
    '-o',
    'ConnectTimeout=15',
    'root@geoffcloud',
    "'systemctl' 'is-active' '--quiet' 'atc-daemon'",
  ]);

  expect(result.exitCode).toBe(3);
});

test('it fails every call as OpenSSH does when the host does not answer', async () => {
  const stub = buildStubRunner(
    buildStubReadinessHost({
      destination: 'root@geoffcloud',
      isUnreachable: true,
      nodeLine: '',
      availableMiB: 0,
      namespaces: [],
      storageClasses: [],
      deployments: {},
      isDaemonActive: true,
      impdHealth: '',
      probeCode: '',
    }),
  );

  const result = await stub.run([
    'ssh',
    '-o',
    'BatchMode=yes',
    '-o',
    'ConnectTimeout=15',
    'root@geoffcloud',
    "'free' '-m'",
  ]);

  expect(result).toStrictEqual({
    exitCode: 255,
    stdout: Buffer.from(''),
    stderr: Buffer.from('ssh: connect to host geoffcloud port 22: Connection timed out\r\n'),
    timedOut: false,
  });
});

test.each([
  [
    'another host',
    ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', 'root@other', "'free' '-m'"],
  ],
  ['no connect timeout', ['ssh', '-o', 'BatchMode=yes', 'root@geoffcloud', "'free' '-m'"]],
  [
    'an unquoted command line',
    ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', 'root@geoffcloud', 'free -m'],
  ],
  [
    'an unknown command',
    ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', 'root@geoffcloud', "'reboot'"],
  ],
] as const)('it fails closed with exit 97 for %s', async (_label, argv) => {
  const stub = buildStubRunner(
    buildStubReadinessHost({
      destination: 'root@geoffcloud',
      nodeLine: '',
      availableMiB: 0,
      namespaces: [],
      storageClasses: [],
      deployments: {},
      isDaemonActive: true,
      impdHealth: '',
      probeCode: '',
    }),
  );

  const result = await stub.run(argv);

  expect(result.exitCode).toBe(97);
  expect(result.stderr.toString()).toBe(`unexpected: ${JSON.stringify(argv)}\n`);
});

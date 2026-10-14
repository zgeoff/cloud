import { topology } from '@zgeoff/cloud-topology';
import type { ReadinessLine } from './format-readiness-line.ts';
import type { HostCheckIO } from './run-host-check.ts';
import { runHostCheck } from './run-host-check.ts';

// a probe pod pulls its image and starts, so it gets longer than a kubectl get
const probeTimeoutMs = 300_000;

// The gateway answers in the cluster with its public Host, and any other Host gets 403. It
// checks nothing before the deploy creates the gateway.
export async function checkGatewayInCluster(
  io: Readonly<HostCheckIO>,
): Promise<readonly ReadinessLine[]> {
  const deploy = await runHostCheck(io, [
    'k3s',
    'kubectl',
    '-n',
    'atc',
    'get',
    'deploy',
    'atc-gateway',
  ]);

  if (deploy.exitCode !== 0) {
    return [];
  }

  const url = `http://atc-gateway.atc.svc.cluster.local:${topology.atc.gatewayPort}/.well-known/oauth-protected-resource/mcp`;
  const pod = ['-n', 'atc', 'run', 'readiness-probe', '--rm', '-i', '--restart=Never', '--quiet'];

  const curl = [
    'curl',
    '-s',
    '-o',
    '/dev/null',
    '-w',
    '%{http_code}',
    '-H',
    'Host: atc.geoff.cloud',
    url,
  ];

  const probe = ['k3s', 'kubectl', ...pod, '--image=curlimages/curl:8.16.0', '--', ...curl];

  const result = await runHostCheck(io, probe, { timeoutMs: probeTimeoutMs });

  const code = result.stdout.toString().trim();

  return [{ status: code === '200' ? 'ok' : 'FAIL', text: `gateway in-cluster metadata: ${code}` }];
}

import type { ReadinessLine } from './format-readiness-line.ts';
import type { HostCheckIO } from './run-host-check.ts';
import { runHostCheck } from './run-host-check.ts';

// the host's own state that the gateway needs: a Ready node, free memory and the tunnel
export async function checkGatewayHost(
  io: Readonly<HostCheckIO>,
): Promise<readonly ReadinessLine[]> {
  const node = await checkNode(io);
  const memory = await checkMemory(io);
  const tunnel = await checkCloudflared(io);

  return [node, memory, tunnel];
}

// the single node's STATUS column, which `get nodes --no-headers` prints second
async function checkNode(io: Readonly<HostCheckIO>): Promise<ReadinessLine> {
  const result = await runHostCheck(io, ['k3s', 'kubectl', 'get', 'nodes', '--no-headers']);

  const lines = result.stdout
    .toString()
    .split('\n')
    .filter((line) => line !== '');

  const statuses = lines.map((line) => line.trim().split(/\s+/u)[1]);
  const isReady = result.exitCode === 0 && statuses.length === 1 && statuses[0] === 'Ready';

  return isReady
    ? { status: 'ok', text: `k3s node on ${io.host} is Ready` }
    : {
        status: 'FAIL',
        text: `k3s node on ${io.host} is not Ready, or ${io.host} is unreachable over the tailnet`,
      };
}

// the gateway needs 256 MiB; the check wants a margin of 1024 MiB in free's available column
async function checkMemory(io: Readonly<HostCheckIO>): Promise<ReadinessLine> {
  const result = await runHostCheck(io, ['free', '-m']);

  const match = /^Mem:(?:\s+\d+){5}\s+(?<available>\d+)\s*$/mu.exec(result.stdout.toString());
  const available = match?.groups?.available;

  if (result.exitCode === 0 && available !== undefined && Number(available) >= 1024) {
    return { status: 'ok', text: `host has ${available} MiB available (gateway needs 256 MiB)` };
  }

  return { status: 'FAIL', text: `host has ${available ?? '?'} MiB available` };
}

async function checkCloudflared(io: Readonly<HostCheckIO>): Promise<ReadinessLine> {
  const jsonpath = ['-o', 'jsonpath={.status.readyReplicas}'];
  const remote = ['k3s', 'kubectl', '-n', 'ingress', 'get', 'deploy', 'cloudflared', ...jsonpath];

  const result = await runHostCheck(io, remote);

  const ready = Number(result.stdout.toString().trim());

  return result.exitCode === 0 && ready >= 1
    ? { status: 'ok', text: 'cloudflared has ready replicas' }
    : { status: 'FAIL', text: 'cloudflared has no ready replica' };
}

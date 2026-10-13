import { isIP } from 'node:net';
import { topology } from '@zgeoff/cloud-topology';
import type { ProbeTarget } from './build-tcp-probe.ts';

export interface RemoteResult {
  readonly exitCode: number;
  readonly stdout: string;
  readonly stderr: string;
}

export interface SandboxTarget extends ProbeTarget {
  // what the address is, for the report: impd, a node, nixie's pod or Service, or the tailnet
  readonly role: 'impd' | 'node' | 'pod' | 'service' | 'tailnet';
}

export type TargetsResult =
  | { readonly ok: true; readonly targets: readonly SandboxTarget[] }
  | { readonly ok: false; readonly error: string };

// impd's API, which nixie's config names by this host
const impdHost = topology.imp.domain;

// Reads, from geoffcloud, each address a fetch sandbox must not reach: impd's addresses on its
// HTTPS port, each node's addresses on the kubelet's port, which listens on every address, and
// nixie's pod and Service on nixie's API port. The tailnet target comes from the caller.
export async function loadSandboxTargets(
  runRemote: (command: string) => Promise<RemoteResult>,
  tailnet: ProbeTarget,
): Promise<TargetsResult> {
  const reads = await Promise.all([
    runRemote(`getent ahosts ${impdHost}`),
    runRemote(
      `k3s kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address} {.items[*].status.addresses[?(@.type=="ExternalIP")].address}'`,
    ),
    runRemote('k3s kubectl -n nixie get pod nixie-0 -o jsonpath={.status.podIP}'),
    runRemote('k3s kubectl -n nixie get service nixie -o jsonpath={.spec.clusterIP}'),
  ]);

  const failed = reads.find((read) => read.exitCode !== 0);

  if (failed !== undefined) {
    return {
      ok: false,
      error: `cannot read the addresses (exit ${failed.exitCode}): ${failed.stderr.trim()}`,
    };
  }

  return buildTargets(
    reads.map((read) => read.stdout),
    tailnet,
  );
}

function buildTargets(outputs: readonly string[], tailnet: ProbeTarget): TargetsResult {
  const [impd = '', nodes = '', pod = '', service = ''] = outputs;

  // getent prints each address once for each socket type, with the address first
  const impdAddresses = new Set(impd.split('\n').map((line) => line.split(/\s+/u)[0] ?? ''));

  const targets: SandboxTarget[] = [
    ...collectAddresses([...impdAddresses].join(' ')).map((host) => ({
      role: 'impd' as const,
      host,
      port: 443,
    })),
    ...collectAddresses(nodes).map((host) => ({ role: 'node' as const, host, port: 10_250 })),
    ...collectAddresses(pod).map((host) => ({ role: 'pod' as const, host, port: 8080 })),
    ...collectAddresses(service).map((host) => ({ role: 'service' as const, host, port: 8080 })),
    { role: 'tailnet', ...tailnet },
  ];

  const missing = (['impd', 'node', 'pod', 'service'] as const).filter(
    (role) => !targets.some((target) => target.role === role),
  );

  return missing.length === 0
    ? { ok: true, targets }
    : { ok: false, error: `found no address for: ${missing.join(', ')}` };
}

// each word that is an IP address, once; anything else never reaches a command line
function collectAddresses(text: string): string[] {
  return [...new Set(text.split(/\s+/u).filter((word) => isIP(word) !== 0))];
}

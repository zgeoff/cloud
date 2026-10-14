import type { Exposure } from './exposure-schema.ts';
import type { Topology } from './topology-schema.ts';

// A host-port entry whose port is also a shared constant, and the constant it must equal
const constantPorts = [
  {
    entry: 'tailscale',
    constant: 'tailnet.directPort',
    read: (t: Topology) => t.tailnet.directPort,
  },
  { entry: 'atc-daemon', constant: 'atc.daemonPort', read: (t: Topology) => t.atc.daemonPort },
  {
    entry: 'grafana',
    constant: 'k3s.grafanaNodePort',
    read: (t: Topology) => t.k3s.grafanaNodePort,
  },
] as const;

// Throws unless each registry port that is also a constant in constants.json holds the same
// value, and names every pair that differs, so the two files cannot drift apart
export function requireExposureMatchesTopology(exposure: Exposure, topology: Topology): void {
  const mismatches = constantPorts.flatMap((pair) => {
    const entry = exposure.entries.find((candidate) => candidate.name === pair.entry);
    const port = entry?.kind === 'host-port' ? entry.port : undefined;
    const expected = pair.read(topology);

    return port === expected
      ? []
      : [
          `exposure entry ${pair.entry} has port ${String(port)}, but ${pair.constant} is ${expected}`,
        ];
  });

  if (mismatches.length > 0) {
    throw new Error(mismatches.join('\n'));
  }
}

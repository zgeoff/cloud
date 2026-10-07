import type { ATCDaemonEndpoint } from './build-alert-rules.ts';
import { toATCDaemonProbeTarget } from './to-atc-daemon-probe-target.ts';

// The chart's own image (its appVersion) and securityContext: non-root, read-only
// root, no capabilities. The host drops, not rejects, a refused connection, so the
// connect times out at 5s, well inside the scrape.
export function buildATCDaemonProbeValues(daemons: readonly ATCDaemonEndpoint[]) {
  return {
    podSecurityContext: { seccompProfile: { type: 'RuntimeDefault' } },
    resources: { requests: { cpu: '10m', memory: '16Mi' }, limits: { memory: '64Mi' } },
    config: { modules: { tcp_connect: { prober: 'tcp', timeout: '5s' } } },
    serviceMonitor: {
      enabled: true,
      defaults: { module: 'tcp_connect', interval: '30s', scrapeTimeout: '10s' },
      targets: daemons.map((daemon) => ({
        name: toATCDaemonProbeTarget(daemon.name),
        url: daemon.address,
      })),
    },
  };
}

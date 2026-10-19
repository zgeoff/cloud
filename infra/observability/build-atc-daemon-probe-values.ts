import type { ATCDaemonEndpoint } from '../inputs/index.ts';
import { buildProbeValues } from './build-probe-values.ts';
import { toATCDaemonProbeTarget } from './to-atc-daemon-probe-target.ts';

export function buildATCDaemonProbeValues(daemons: readonly ATCDaemonEndpoint[]) {
  return buildProbeValues({
    // The host drops, not rejects, a refused connection, so the connect times out at 5s, well
    // inside the scrape.
    modules: { tcp_connect: { prober: 'tcp', timeout: '5s' } },
    module: 'tcp_connect',
    targets: daemons.map((daemon) => ({
      name: toATCDaemonProbeTarget(daemon.name),
      url: daemon.address,
    })),
  });
}

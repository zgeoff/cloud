import type { Namespace } from '@pulumi/kubernetes/core/v1';
import { Chart } from '@pulumi/kubernetes/helm/v4';
import type { ComponentResourceOptions } from '@pulumi/pulumi';
import type { ATCDaemonEndpoint } from './build-alert-rules.ts';
import { toATCDaemonProbeTarget } from './to-atc-daemon-probe-target.ts';

// The blackbox exporter, probing each of atc's daemons with a TCP connect from a pod
// every 30s, one ServiceMonitor per daemon. The pod's connection takes the same path as
// the gateway's: to geoffcloud's daemon, cni0 from 10.42.0.0/16, which the host's
// cloud_host table admits to the daemon's port; to another host's, the tailnet. ATCDaemonUnreachable
// (build-alert-rules.ts) alerts on the result. The chart's ServiceMonitor carries the
// probe, and Prometheus picks up every ServiceMonitor (observability.ts). opts
// carries the cluster and the dependency on kube-prometheus-stack, which brings the
// ServiceMonitor CRD.
export function createATCDaemonProbe(
  ns: Namespace,
  daemons: readonly ATCDaemonEndpoint[],
  opts: ComponentResourceOptions,
): Chart {
  return new Chart(
    'atc-daemon-probe',
    {
      namespace: ns.metadata.name,
      chart: 'prometheus-blackbox-exporter',
      version: '11.19.1',
      repositoryOpts: { repo: 'https://prometheus-community.github.io/helm-charts' },
      values: buildProbeValues(daemons),
    },
    opts,
  );
}

// The chart's own image (its appVersion) and securityContext: non-root, read-only
// root, no capabilities. The host drops, not rejects, a refused connection, so the
// connect times out at 5s, well inside the scrape.
function buildProbeValues(daemons: readonly ATCDaemonEndpoint[]): Record<string, unknown> {
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

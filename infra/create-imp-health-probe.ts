import type { Namespace } from '@pulumi/kubernetes/core/v1';
import { Chart } from '@pulumi/kubernetes/helm/v4';
import type { ComponentResourceOptions } from '@pulumi/pulumi';
import { impHealthProbeTarget } from './imp-health-probe-target.ts';

// The blackbox exporter, fetching imp's /health from a pod every 30s over the path
// clients take (#29): public DNS gives imp's tailnet address, the pod's connection leaves
// through the host's tailnet node, and the tailnet policy lets tag:cloud reach imp's node
// on 443 only (tailnet-policy.ts). ImpHealthUnreachable (build-alert-rules.ts) alerts on
// the result. A chart of its own, so the atc daemon probe stays as it is. /health needs no
// credentials, so the probe carries none.
export function createImpHealthProbe(ns: Namespace, opts: ComponentResourceOptions): Chart {
  return new Chart(
    'imp-health-probe',
    {
      namespace: ns.metadata.name,
      chart: 'prometheus-blackbox-exporter',
      version: '11.19.1',
      repositoryOpts: { repo: 'https://prometheus-community.github.io/helm-charts' },
      values: impHealthProbeValues,
    },
    opts,
  );
}

const impHealthURL = 'https://imps.geoff.cloud/health';

// TLS must verify (the default; fail_if_not_ssl refuses plain HTTP), and the body must
// say impd is ready, so a 200 from anything else fails. The chart's own image and
// securityContext, as for the atc daemon probe.
const impHealthProbeValues: Record<string, unknown> = {
  podSecurityContext: { seccompProfile: { type: 'RuntimeDefault' } },
  resources: { requests: { cpu: '10m', memory: '16Mi' }, limits: { memory: '64Mi' } },
  config: {
    modules: {
      imp_health: {
        prober: 'http',
        timeout: '5s',
        http: {
          preferred_ip_protocol: 'ip4',
          valid_status_codes: [200],
          fail_if_not_ssl: true,
          fail_if_body_not_matches_regexp: [String.raw`"ready":\s*true`],
        },
      },
    },
  },
  serviceMonitor: {
    enabled: true,
    defaults: { module: 'imp_health', interval: '30s', scrapeTimeout: '10s' },
    targets: [{ name: impHealthProbeTarget, url: impHealthURL }],
  },
};

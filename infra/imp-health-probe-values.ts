import { impHealthProbeTarget } from './imp-health-probe-target.ts';

const impHealthURL = 'https://imps.geoff.cloud/health';

// TLS must verify (the default; fail_if_not_ssl refuses plain HTTP), and the body must
// say impd is ready, so a 200 from anything else fails. The chart's own image and
// securityContext, as for the atc daemon probe.
export const impHealthProbeValues = {
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

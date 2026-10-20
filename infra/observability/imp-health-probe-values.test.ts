import { expect, test } from 'bun:test';
import { impHealthProbeValues } from './imp-health-probe-values.ts';

// test-imp-health-probe.sh runs the module in the pinned blackbox exporter against impd's ready
// and not-ready bodies, since only the exporter evaluates its CEL expression
test("it probes imp's /health over verified TLS every 30s from the pod its egress allow selects, failing unless the JSON body says impd is ready", () => {
  expect(impHealthProbeValues).toStrictEqual({
    pod: { labels: { app: 'imp-health-probe' } },
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
            fail_if_body_json_not_matches_cel: 'body.ready == true',
          },
        },
      },
    },
    serviceMonitor: {
      enabled: true,
      defaults: { module: 'imp_health', interval: '30s', scrapeTimeout: '10s' },
      targets: [{ name: 'imp-health', url: 'https://imps.geoff.cloud/health' }],
    },
  });
});

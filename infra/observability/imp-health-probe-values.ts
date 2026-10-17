import { topology } from '@zgeoff/cloud-topology';
import { buildProbeValues } from './build-probe-values.ts';
import { impHealthProbeTarget } from './imp-health-probe-target.ts';

const impHealthURL = `https://${topology.imp.domain}/health`;

// TLS must verify (fail_if_not_ssl refuses plain HTTP), and the body must parse as JSON whose
// ready is true, so a 200 from anything else fails. CEL body checks need blackbox exporter 0.27.0
// or later; test-imp-health-probe.sh runs this module in the chart's exporter.
export const impHealthProbeValues = buildProbeValues({
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
  module: 'imp_health',
  targets: [{ name: impHealthProbeTarget, url: impHealthURL }],
});

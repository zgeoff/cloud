import { topology } from '@zgeoff/cloud-topology';
import { buildProbeValues } from './build-probe-values.ts';
import { impHealthProbeTarget } from './imp-health-probe-target.ts';

const impHealthURL = `https://${topology.imp.domain}/health`;

// TLS must verify (the default; fail_if_not_ssl refuses plain HTTP), and the body must
// say impd is ready, so a 200 from anything else fails.
export const impHealthProbeValues = buildProbeValues({
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
  module: 'imp_health',
  targets: [{ name: impHealthProbeTarget, url: impHealthURL }],
});

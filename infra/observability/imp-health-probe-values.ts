import { topology } from '@zgeoff/cloud-topology';
import { podLabels } from '../shared/pod-labels.ts';
import { buildProbeValues } from './build-probe-values.ts';
import { impHealthProbeTarget } from './imp-health-probe-target.ts';

const impHealthURL = `https://${topology.imp.domain}/health`;

export const impHealthProbeValues = buildProbeValues({
  modules: {
    imp_health: {
      prober: 'http',
      timeout: '5s',
      http: {
        preferred_ip_protocol: 'ip4',
        valid_status_codes: [200],
        fail_if_not_ssl: true,

        // a 200 from anything else fails; CEL body checks need blackbox exporter 0.27.0 or later
        fail_if_body_json_not_matches_cel: 'body.ready == true',
      },
    },
  },
  module: 'imp_health',
  podLabels: podLabels.impHealthProbe,
  targets: [{ name: impHealthProbeTarget, url: impHealthURL }],
});

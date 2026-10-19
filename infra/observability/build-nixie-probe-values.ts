import { buildProbeValues } from './build-probe-values.ts';
import { nixieProbeTargets } from './nixie-probe-targets.ts';

export function buildNixieProbeValues(readinessURL: string) {
  return buildProbeValues({
    modules: {
      nixie_turns: {
        prober: 'http',
        timeout: '5s',
        http: {
          preferred_ip_protocol: 'ip4',
          valid_status_codes: [200],

          // /health/ready answers 200 while the turns fail, so the body decides; a brace in the
          // advisory part's reason fails the match
          fail_if_body_not_matches_regexp: [
            String.raw`"conversation_turns":\s*\{[^{}]*"isReady":\s*true`,
          ],
        },
      },
      nixie_status: {
        prober: 'http',
        timeout: '5s',
        http: {
          preferred_ip_protocol: 'ip4',
          valid_status_codes: [200],
          fail_if_body_not_matches_regexp: [String.raw`^\{"status":\s*"ready"`],
        },
      },
    },
    module: 'nixie_turns',
    targets: [
      { name: nixieProbeTargets.turns, url: readinessURL },
      { name: nixieProbeTargets.status, url: readinessURL, module: 'nixie_status' },
    ],
  });
}

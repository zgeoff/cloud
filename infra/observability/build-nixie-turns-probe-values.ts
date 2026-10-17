import { buildProbeValues } from './build-probe-values.ts';
import { nixieTurnsProbeTarget } from './nixie-turns-probe-target.ts';

// nixie's /health/ready answers 200 while its turns fail (zgeoff/nixie#318), so the probe passes
// only on a body whose advisory conversation_turns says isReady true. A reason with a brace in it
// fails the match, never passes it.
export function buildNixieTurnsProbeValues(readinessURL: string) {
  return buildProbeValues({
    modules: {
      nixie_turns: {
        prober: 'http',
        timeout: '5s',
        http: {
          preferred_ip_protocol: 'ip4',
          valid_status_codes: [200],
          fail_if_body_not_matches_regexp: [
            String.raw`"conversation_turns":\s*\{[^{}]*"isReady":\s*true`,
          ],
        },
      },
    },
    module: 'nixie_turns',
    targets: [{ name: nixieTurnsProbeTarget, url: readinessURL }],
  });
}

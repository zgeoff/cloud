import { expect, test } from 'bun:test';
import { impHealthProbeValues } from './imp-health-probe-values.ts';

test("it probes imp's /health over verified TLS every 30s, failing unless the body says impd is ready", () => {
  expect(impHealthProbeValues).toStrictEqual({
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
      targets: [{ name: 'imp-health', url: 'https://imps.geoff.cloud/health' }],
    },
  });
});

// impd's /health body as its daemon serves it: `{ status: 'ok', ready: deps.isReady() }`
// as JSON (zgeoff/imp packages/daemon/src/build-app.ts at 51df459d)
test.each([
  ['{"status":"ok","ready":true}', true],
  ['{"status":"ok","ready":false}', false],
  ['{"status":"ok"}', false],
])('it matches the body %s as ready: %p', (body, ready) => {
  const [pattern] =
    impHealthProbeValues.config.modules.imp_health.http.fail_if_body_not_matches_regexp;

  if (pattern === undefined) {
    throw new Error('expected a body pattern');
  }

  expect(new RegExp(pattern, 'u').test(body)).toBe(ready);
});

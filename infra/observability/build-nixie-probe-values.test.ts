import { expect, test } from 'bun:test';
import invariant from 'tiny-invariant';
import { buildNixieProbeValues } from './build-nixie-probe-values.ts';

test("it probes nixie's readiness report every 30s for passing turns and for the status ready", () => {
  expect(
    buildNixieProbeValues('http://nixie.nixie.svc.cluster.local:8080/health/ready'),
  ).toStrictEqual({
    podSecurityContext: { seccompProfile: { type: 'RuntimeDefault' } },
    resources: { requests: { cpu: '10m', memory: '16Mi' }, limits: { memory: '64Mi' } },
    config: {
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
    },
    serviceMonitor: {
      enabled: true,
      defaults: { module: 'nixie_turns', interval: '30s', scrapeTimeout: '10s' },
      targets: [
        {
          name: 'nixie-turns',
          url: 'http://nixie.nixie.svc.cluster.local:8080/health/ready',
        },
        {
          name: 'nixie-status',
          url: 'http://nixie.nixie.svc.cluster.local:8080/health/ready',
          module: 'nixie_status',
        },
      ],
    },
  });
});

const readyParts = {
  database: { isReady: true, reason: null },
  definitions: { isReady: true, reason: null },
  imp_host: { isReady: true, reason: null },
  conversation_imp: { isReady: true, reason: null },
  disk: { isReady: true, reason: null },
};

// nixie's /health/ready body as Response.json writes it: the status, each readiness part, and each
// advisory part, each part as { isReady, reason } (zgeoff/nixie modules/ops/src/build-health-app.ts
// and types.ts at 9afa077)
test.each([
  [
    'clear turns',
    {
      status: 'ready',
      parts: readyParts,
      advisory: { conversation_turns: { isReady: true, reason: null } },
    },
    true,
  ],
  [
    'failing turns',
    {
      status: 'ready',
      parts: readyParts,
      advisory: { conversation_turns: { isReady: false, reason: 'the last 3 turns failed' } },
    },
    false,
  ],
  [
    'turns failing at the sandbox host',
    {
      status: 'ready',
      parts: readyParts,
      advisory: {
        conversation_turns: {
          isReady: false,
          reason: 'the last 4 turns failed, the last at the sandbox host with RAM_BUDGET_EXCEEDED',
        },
      },
    },
    false,
  ],
  [
    'failing turns whose reason holds a brace',
    {
      status: 'ready',
      parts: readyParts,
      advisory: { conversation_turns: { isReady: false, reason: 'a step {3} failed' } },
    },
    false,
  ],
  ['no advisory part, as before nixie 0.29.1', { status: 'ready', parts: readyParts }, false],
])('it reads a body with %s as passing the turns probe: %p', (_kind, body, isPassing) => {
  const [pattern] = buildNixieProbeValues('http://nixie.test/health/ready').config.modules
    .nixie_turns.http.fail_if_body_not_matches_regexp;

  invariant(pattern !== undefined, 'expected a body pattern');

  expect(new RegExp(pattern, 'u').test(JSON.stringify(body))).toBe(isPassing);
});

// nixie's /health/ready body with its dependency parts, as Response.json writes it, the status first
// (zgeoff/nixie modules/ops/src/build-health-app.ts)
test.each([
  [
    'the status ready',
    {
      status: 'ready',
      parts: { database: { isReady: true, reason: null } },
      dependencies: { imp_host: { isReady: true, reason: null } },
    },
    true,
  ],
  [
    'the status degraded',
    {
      status: 'degraded',
      parts: { database: { isReady: true, reason: null } },
      dependencies: { imp_host: { isReady: false, reason: 'the check took longer than 2000 ms' } },
    },
    false,
  ],
  [
    'the status unready',
    {
      status: 'unready',
      parts: { database: { isReady: false, reason: 'the migrations have not run' } },
      dependencies: { imp_host: { isReady: true, reason: null } },
    },
    false,
  ],
  [
    'the status degraded and a reason that quotes the status ready',
    {
      status: 'degraded',
      parts: { database: { isReady: true, reason: null } },
      dependencies: { disk: { isReady: false, reason: '"status":"ready"' } },
    },
    false,
  ],
])('it reads a body with %s as passing the status probe: %p', (_kind, body, isPassing) => {
  const [pattern] = buildNixieProbeValues('http://nixie.test/health/ready').config.modules
    .nixie_status.http.fail_if_body_not_matches_regexp;

  invariant(pattern !== undefined, 'expected a body pattern');

  expect(new RegExp(pattern, 'u').test(JSON.stringify(body))).toBe(isPassing);
});

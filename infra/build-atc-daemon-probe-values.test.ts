import { expect, test } from 'bun:test';
import { buildAlertRules } from './build-alert-rules.ts';
import { buildATCDaemonProbeValues } from './build-atc-daemon-probe-values.ts';
import { buildMockATCDaemonEndpoint } from './test-utils/build-mock-atc-daemon-endpoint.ts';

test("it probes each daemon's address with a TCP connect, keeping geoffcloud's original target name", () => {
  const daemons = [
    buildMockATCDaemonEndpoint({ name: 'geoffcloud', address: '100.69.47.33:8415' }),
    buildMockATCDaemonEndpoint({ name: 'home-pc', address: '100.67.122.120:8415' }),
  ];

  expect(buildATCDaemonProbeValues(daemons)).toStrictEqual({
    podSecurityContext: { seccompProfile: { type: 'RuntimeDefault' } },
    resources: { requests: { cpu: '10m', memory: '16Mi' }, limits: { memory: '64Mi' } },
    config: { modules: { tcp_connect: { prober: 'tcp', timeout: '5s' } } },
    serviceMonitor: {
      enabled: true,
      defaults: { module: 'tcp_connect', interval: '30s', scrapeTimeout: '10s' },
      targets: [
        { name: 'atc-daemon', url: '100.69.47.33:8415' },
        { name: 'atc-daemon-home-pc', url: '100.67.122.120:8415' },
      ],
    },
  });
});

test('it probes no target without daemons', () => {
  expect(buildATCDaemonProbeValues([])).toStrictEqual({
    podSecurityContext: { seccompProfile: { type: 'RuntimeDefault' } },
    resources: { requests: { cpu: '10m', memory: '16Mi' }, limits: { memory: '64Mi' } },
    config: { modules: { tcp_connect: { prober: 'tcp', timeout: '5s' } } },
    serviceMonitor: {
      enabled: true,
      defaults: { module: 'tcp_connect', interval: '30s', scrapeTimeout: '10s' },
      targets: [],
    },
  });
});

test("it names each probe target as the daemon's alert rule selects it", () => {
  const daemons = [
    buildMockATCDaemonEndpoint({ name: 'geoffcloud' }),
    buildMockATCDaemonEndpoint({ name: 'home-pc' }),
  ];

  const targets = buildATCDaemonProbeValues(daemons).serviceMonitor.targets.map(
    (target) => target.name,
  );

  const [group] = buildAlertRules({ atcDaemons: daemons });

  const exprs = group?.rules
    .filter((rule) => rule.alert === 'ATCDaemonUnreachable')
    .map((rule) => rule.expr);

  expect({ targets, exprs }).toStrictEqual({
    targets: ['atc-daemon', 'atc-daemon-home-pc'],
    exprs: [
      'probe_success{target="atc-daemon"} == 0 or absent(probe_success{target="atc-daemon"})',
      'probe_success{target="atc-daemon-home-pc"} == 0 or absent(probe_success{target="atc-daemon-home-pc"})',
    ],
  });
});

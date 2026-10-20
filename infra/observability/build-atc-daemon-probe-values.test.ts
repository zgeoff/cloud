import { expect, test } from 'bun:test';
import { buildMockATCDaemonEndpoint } from '../test-utils/build-mock-atc-daemon-endpoint.ts';
import { buildATCDaemonProbeValues } from './build-atc-daemon-probe-values.ts';

test("it probes each daemon's address with a TCP connect from the pod its egress allow selects, keeping geoffcloud's original target name", () => {
  const daemons = [
    buildMockATCDaemonEndpoint({ name: 'geoffcloud', address: '100.69.47.33:8415' }),
    buildMockATCDaemonEndpoint({ name: 'home-pc', address: '100.67.122.120:8415' }),
  ];

  expect(buildATCDaemonProbeValues(daemons)).toStrictEqual({
    pod: { labels: { app: 'atc-daemon-probe' } },
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
    pod: { labels: { app: 'atc-daemon-probe' } },
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

import { expect, test } from 'bun:test';
import { buildProbeValues } from './build-probe-values.ts';

test('it probes every target every 30s with the named module, on the chart image under a locked-down pod', () => {
  expect(
    buildProbeValues({
      modules: { icmp_ping: { prober: 'icmp', timeout: '2s' } },
      module: 'icmp_ping',
      targets: [
        { name: 'router', url: '192.0.2.1' },
        { name: 'printer', url: '192.0.2.7' },
      ],
    }),
  ).toStrictEqual({
    podSecurityContext: { seccompProfile: { type: 'RuntimeDefault' } },
    resources: { requests: { cpu: '10m', memory: '16Mi' }, limits: { memory: '64Mi' } },
    config: { modules: { icmp_ping: { prober: 'icmp', timeout: '2s' } } },
    serviceMonitor: {
      enabled: true,
      defaults: { module: 'icmp_ping', interval: '30s', scrapeTimeout: '10s' },
      targets: [
        { name: 'router', url: '192.0.2.1' },
        { name: 'printer', url: '192.0.2.7' },
      ],
    },
  });
});

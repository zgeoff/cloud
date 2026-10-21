/* oxlint-disable id-length -- Grafana's gridPos names a panel's width w and its height h */
import { expect, test } from 'bun:test';
import { buildHostCPUDashboard } from './build-host-cpu-dashboard.ts';

test("it charts the host's kernel CPU beside each top-level cgroup's CPU from Prometheus", () => {
  expect(buildHostCPUDashboard()).toStrictEqual({
    uid: 'geoff-cloud-host-cpu',
    title: 'host-cpu',
    tags: ['geoff.cloud'],
    timezone: 'utc',
    schemaVersion: 39,
    refresh: '1m',
    time: { from: 'now-24h', to: 'now' },
    templating: {
      list: [{ name: 'datasource', type: 'datasource', query: 'prometheus', hide: 2 }],
    },
    panels: [
      {
        id: 1,
        title: 'Kernel CPU (cores)',
        type: 'timeseries',
        datasource: { type: 'prometheus', uid: '$datasource' },
        gridPos: { x: 0, y: 0, w: 12, h: 8 },
        targets: [
          {
            refId: 'A',
            datasource: { type: 'prometheus', uid: '$datasource' },
            expr: 'sum(rate(host_kernel_cpu_seconds_total[5m]))',
            legendFormat: 'kernel threads and interrupts',
          },
        ],
      },
      {
        id: 2,
        title: 'CPU by top-level cgroup (cores)',
        type: 'timeseries',
        datasource: { type: 'prometheus', uid: '$datasource' },
        gridPos: { x: 12, y: 0, w: 12, h: 8 },
        targets: [
          {
            refId: 'A',
            datasource: { type: 'prometheus', uid: '$datasource' },
            expr: 'sum by (cgroup) (rate(host_cgroup_cpu_seconds_total{cgroup=~"/[^/]+"}[5m]))',
            legendFormat: '{{cgroup}}',
          },
        ],
      },
    ],
  });
});

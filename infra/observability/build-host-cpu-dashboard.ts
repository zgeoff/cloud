import { buildDashboard } from './build-dashboard.ts';

export function buildHostCPUDashboard(): Record<string, unknown> {
  return buildDashboard('host-cpu', 'prometheus', [
    {
      title: 'Kernel CPU (cores)',
      type: 'timeseries',
      expr: 'sum(rate(host_kernel_cpu_seconds_total[5m]))',
      legend: 'kernel threads and interrupts',
      width: 12,
      height: 8,
    },
    {
      title: 'CPU by top-level cgroup (cores)',
      type: 'timeseries',
      expr: 'sum by (cgroup) (rate(host_cgroup_cpu_seconds_total{cgroup=~"/[^/]+"}[5m]))',
      legend: '{{cgroup}}',
      width: 12,
      height: 8,
    },
  ]);
}

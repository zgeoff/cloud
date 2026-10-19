import { buildDashboard } from './build-dashboard.ts';
import type { DashboardPanel } from './build-dashboard.ts';

// impd logs to journald through imp-host.service; it exports no metrics (no OTLP)
const impdStream = '{job="journal", unit="imp-host.service"}';

const impPanels: readonly DashboardPanel[] = [
  {
    title: 'impd log lines',
    type: 'timeseries',
    expr: `sum(count_over_time(${impdStream} [$__auto]))`,
    legend: 'lines',
    width: 12,
    height: 8,
  },
  {
    title: 'impd errors and warnings',
    type: 'timeseries',
    expr: `sum(count_over_time(${impdStream} |~ "(?i)error|fail|warning" [$__auto]))`,
    legend: 'errors and warnings',
    width: 12,
    height: 8,
  },
  {
    title: 'Boot template restores',
    type: 'stat',
    expr: `sum(count_over_time(${impdStream} |= "restored boot template" [$__range]))`,
    width: 6,
    height: 5,
  },
  {
    title: 'Cold-boot fallbacks',
    type: 'stat',
    expr: `sum(count_over_time(${impdStream} |= "booting the kernel" [$__range]))`,
    width: 6,
    height: 5,
  },
  {
    title: 'Backups',
    type: 'stat',
    expr: `sum(count_over_time(${impdStream} |~ "impd: backup: [0-9a-f]+:" [$__range]))`,
    width: 6,
    height: 5,
  },
  {
    title: 'imp-docker-proxy log lines',
    type: 'stat',
    expr: 'sum(count_over_time({job="journal", unit="imp-docker-proxy.service"} [$__range]))',
    width: 6,
    height: 5,
  },
  { title: 'impd logs', type: 'logs', expr: impdStream, width: 24, height: 12 },
];

export function buildIMPDashboard(): Record<string, unknown> {
  return buildDashboard('imp', 'loki', impPanels);
}

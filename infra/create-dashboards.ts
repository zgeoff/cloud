import type { Provider } from '@pulumi/kubernetes';
import { ConfigMap } from '@pulumi/kubernetes/core/v1';
import type { Namespace } from '@pulumi/kubernetes/core/v1';
import { buildDashboard } from './build-dashboard.ts';
import type { DashboardPanel } from './build-dashboard.ts';

// Grafana's dashboard sidecar loads every ConfigMap labelled grafana_dashboard=1 (#27)
export function createDashboards(ns: Namespace, cluster: Provider): ConfigMap[] {
  const dashboards = { imp: buildIMPDashboard(), cloudflared: buildCloudflaredDashboard() };

  return Object.entries(dashboards).map(
    ([name, dashboard]) =>
      new ConfigMap(
        `dashboard-${name}`,
        {
          metadata: {
            name: `dashboard-${name}`,
            namespace: ns.metadata.name,
            labels: { grafana_dashboard: '1' },
          },
          data: { [`${name}.json`]: JSON.stringify(dashboard) },
        },
        { provider: cluster },
      ),
  );
}

// impd logs to journald through imp-host.service; it exports no metrics (no OTLP, #8)
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

function buildIMPDashboard(): Record<string, unknown> {
  return buildDashboard('imp', 'loki', impPanels);
}

function buildCloudflaredDashboard(): Record<string, unknown> {
  return buildDashboard('cloudflared', 'prometheus', [
    {
      title: 'Tunnel HA connections',
      type: 'stat',
      expr: 'sum(cloudflared_tunnel_ha_connections)',
      width: 6,
      height: 5,
    },
    {
      title: 'Concurrent requests',
      type: 'stat',
      expr: 'sum(cloudflared_tunnel_concurrent_requests_per_tunnel)',
      width: 6,
      height: 5,
    },
    {
      title: 'Request errors (5m)',
      type: 'stat',
      expr: 'sum(increase(cloudflared_tunnel_request_errors[5m]))',
      width: 6,
      height: 5,
    },
    {
      title: 'Edge locations',
      type: 'stat',
      expr: 'count(cloudflared_tunnel_server_locations > 0)',
      width: 6,
      height: 5,
    },
    {
      title: 'Requests per second',
      type: 'timeseries',
      expr: 'sum by (pod) (rate(cloudflared_tunnel_total_requests[5m]))',
      legend: '{{pod}}',
      width: 12,
      height: 8,
    },
    {
      title: 'Responses by status code',
      type: 'timeseries',
      expr: 'sum by (status_code) (rate(cloudflared_tunnel_response_by_code[5m]))',
      legend: '{{status_code}}',
      width: 12,
      height: 8,
    },
  ]);
}

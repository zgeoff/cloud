import type { Provider } from '@pulumi/kubernetes';
import { ConfigMap } from '@pulumi/kubernetes/core/v1';
import type { Namespace } from '@pulumi/kubernetes/core/v1';

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

interface Panel {
  readonly title: string;
  readonly type: 'timeseries' | 'stat' | 'logs';
  readonly expr: string;
  readonly legend?: string;
  readonly width: number;
  readonly height: number;
}

// impd logs to journald through imp-host.service; it exports no metrics (no OTLP, #8)
const impdStream = '{job="journal", unit="imp-host.service"}';

const impPanels: readonly Panel[] = [
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

// the datasource is a variable, so the dashboard does not depend on a generated datasource uid
function buildDashboard(
  title: string,
  datasourceType: 'loki' | 'prometheus',
  panels: readonly Panel[],
): Record<string, unknown> {
  const datasource = { type: datasourceType, uid: '$datasource' };
  const positions = buildGridPositions(panels);

  return {
    uid: `geoff-cloud-${title}`,
    title,
    tags: ['geoff.cloud'],
    timezone: 'utc',
    schemaVersion: 39,
    refresh: '1m',
    time: { from: 'now-24h', to: 'now' },
    templating: {
      list: [{ name: 'datasource', type: 'datasource', query: datasourceType, hide: 2 }],
    },
    panels: panels.map((panel, index) => ({
      id: index + 1,
      title: panel.title,
      type: panel.type,
      datasource,
      gridPos: positions[index],
      targets: [
        {
          refId: 'A',
          datasource,
          expr: panel.expr,
          ...(panel.legend === undefined ? {} : { legendFormat: panel.legend }),
          ...(panel.type === 'stat' ? { instant: true, queryType: 'instant' } : {}),
        },
      ],
      ...(panel.type === 'stat' ? { options: { reduceOptions: { calcs: ['lastNotNull'] } } } : {}),
    })),
  };
}

interface GridPosition {
  readonly x: number;
  readonly y: number;
  readonly w: number;
  readonly h: number;
}

// panels flow left to right in rows of 24 columns
function buildGridPositions(panels: readonly Panel[]): GridPosition[] {
  let x = 0;
  let y = 0;
  let rowHeight = 0;

  return panels.map((panel) => {
    if (x + panel.width > 24) {
      x = 0;
      y += rowHeight;
      rowHeight = 0;
    }

    const position = { x, y, w: panel.width, h: panel.height };

    x += panel.width;
    rowHeight = Math.max(rowHeight, panel.height);

    return position;
  });
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

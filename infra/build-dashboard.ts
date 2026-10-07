import { buildGridPositions } from './build-grid-positions.ts';

// one panel and its one query; width and height in grid units, 24 to a row
export interface DashboardPanel {
  readonly title: string;
  readonly type: 'timeseries' | 'stat' | 'logs';
  readonly expr: string;
  readonly legend?: string;
  readonly width: number;
  readonly height: number;
}

// the datasource is a variable, so the dashboard does not depend on a generated datasource uid
export function buildDashboard(
  title: string,
  datasourceType: 'loki' | 'prometheus',
  panels: readonly DashboardPanel[],
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

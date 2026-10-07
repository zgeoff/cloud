// the test asserts the whole dashboard as one literal, so its body is long
/* oxlint-disable max-lines-per-function */
import { expect, test } from 'bun:test';
import { buildDashboard } from './build-dashboard.ts';

test('it makes stat panels instant queries reduced to the last value, and gives a legend only where the panel sets one', () => {
  expect(
    buildDashboard('imp', 'loki', [
      {
        title: 'impd log lines',
        type: 'timeseries',
        expr: 'sum(count_over_time({unit="imp-host.service"} [$__auto]))',
        legend: 'lines',
        width: 12,
        height: 8,
      },
      {
        title: 'Backups',
        type: 'stat',
        expr: 'sum(count_over_time({unit="imp-host.service"} [$__range]))',
        width: 12,
        height: 5,
      },
      {
        title: 'impd logs',
        type: 'logs',
        expr: '{unit="imp-host.service"}',
        width: 24,
        height: 12,
      },
    ]),
  ).toStrictEqual({
    uid: 'geoff-cloud-imp',
    title: 'imp',
    tags: ['geoff.cloud'],
    timezone: 'utc',
    schemaVersion: 39,
    refresh: '1m',
    time: { from: 'now-24h', to: 'now' },
    templating: {
      list: [{ name: 'datasource', type: 'datasource', query: 'loki', hide: 2 }],
    },
    panels: [
      {
        id: 1,
        title: 'impd log lines',
        type: 'timeseries',
        datasource: { type: 'loki', uid: '$datasource' },
        gridPos: { x: 0, y: 0, w: 12, h: 8 },
        targets: [
          {
            refId: 'A',
            datasource: { type: 'loki', uid: '$datasource' },
            expr: 'sum(count_over_time({unit="imp-host.service"} [$__auto]))',
            legendFormat: 'lines',
          },
        ],
      },
      {
        id: 2,
        title: 'Backups',
        type: 'stat',
        datasource: { type: 'loki', uid: '$datasource' },
        gridPos: { x: 12, y: 0, w: 12, h: 5 },
        targets: [
          {
            refId: 'A',
            datasource: { type: 'loki', uid: '$datasource' },
            expr: 'sum(count_over_time({unit="imp-host.service"} [$__range]))',
            instant: true,
            queryType: 'instant',
          },
        ],
        options: { reduceOptions: { calcs: ['lastNotNull'] } },
      },
      {
        id: 3,
        title: 'impd logs',
        type: 'logs',
        datasource: { type: 'loki', uid: '$datasource' },
        gridPos: { x: 0, y: 8, w: 24, h: 12 },
        targets: [
          {
            refId: 'A',
            datasource: { type: 'loki', uid: '$datasource' },
            expr: '{unit="imp-host.service"}',
          },
        ],
      },
    ],
  });
});

test('it selects the datasource by a variable of the dashboard datasource type', () => {
  expect(buildDashboard('cloudflared', 'prometheus', [])).toStrictEqual({
    uid: 'geoff-cloud-cloudflared',
    title: 'cloudflared',
    tags: ['geoff.cloud'],
    timezone: 'utc',
    schemaVersion: 39,
    refresh: '1m',
    time: { from: 'now-24h', to: 'now' },
    templating: {
      list: [{ name: 'datasource', type: 'datasource', query: 'prometheus', hide: 2 }],
    },
    panels: [],
  });
});

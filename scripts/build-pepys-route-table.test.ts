import { expect, test } from 'bun:test';
import { buildPepysRouteTable } from './build-pepys-route-table.ts';

test('it lists each receive route with its reach, private by default, and each variable once in the order ingest reads them', () => {
  const appEnv = ['WIDGET_APP_ID', 'WIDGET_APP_KEY'];

  expect(
    buildPepysRouteTable({
      name: 'example',
      plugins: [
        {
          name: 'widgets',
          sources: [
            {
              name: 'widgets',
              families: [],
              live: {
                kind: 'receive',
                route: '/hooks/widgets',
                check: { kind: 'hmac-sha256', header: 'x-signature', secretEnv: 'WIDGET_SECRET' },
                reach: 'public',
              },
              recovery: { kind: 'pull', name: 'redeliver', env: appEnv },
              resync: { kind: 'pull', name: 'resync', env: appEnv },
            },
          ],
        },
        {
          name: 'meters',
          sources: [
            {
              name: 'meters',
              live: {
                kind: 'receive',
                route: '/v1/logs',
                ignoredRoutes: ['/v1/metrics'],
                check: { kind: 'token', header: 'authorization', secretEnv: 'METER_TOKEN' },
              },
            },
            { name: 'polls', live: { kind: 'pull', env: ['POLL_TOKEN'] } },
          ],
        },
      ],
    }),
  ).toStrictEqual({
    routes: [
      { source: 'widgets', route: '/hooks/widgets', reach: 'public' },
      { source: 'meters', route: '/v1/logs', reach: 'private' },
      { source: 'meters', route: '/v1/metrics', reach: 'private' },
    ],
    secretVariables: [
      'WIDGET_SECRET',
      'WIDGET_APP_ID',
      'WIDGET_APP_KEY',
      'METER_TOKEN',
      'POLL_TOKEN',
    ],
  });
});

test("it lists each sender route after its path's own routes, with the path's reach and no variable", () => {
  expect(
    buildPepysRouteTable({
      plugins: [
        {
          sources: [
            {
              name: 'meters',
              live: {
                kind: 'receive',
                route: '/v1/logs',
                ignoredRoutes: ['/v1/metrics'],
                check: { kind: 'token', header: 'authorization', secretEnv: 'METER_TOKEN' },
                senderRoutes: [
                  {
                    route: '/relayed/v1/logs',
                    sender: {
                      kind: 'imp-identity',
                      audienceEnv: 'METER_RELAY_AUDIENCE',
                      issuersEnv: 'METER_RELAY_ISSUERS',
                    },
                  },
                ],
              },
            },
            {
              name: 'gauges',
              live: {
                kind: 'receive',
                route: '/hooks/gauges',
                check: { kind: 'hmac-sha256', header: 'x-signature', secretEnv: 'GAUGE_SECRET' },
                reach: 'public',
              },
            },
          ],
        },
      ],
    }),
  ).toStrictEqual({
    routes: [
      { source: 'meters', route: '/v1/logs', reach: 'private' },
      { source: 'meters', route: '/v1/metrics', reach: 'private' },
      { source: 'meters', route: '/relayed/v1/logs', reach: 'private' },
      { source: 'gauges', route: '/hooks/gauges', reach: 'public' },
    ],
    secretVariables: ['METER_TOKEN', 'GAUGE_SECRET'],
  });
});

test('it refuses a value that is not a deployment', () => {
  expect(() => buildPepysRouteTable({ plugins: 'none' })).toThrow();
});

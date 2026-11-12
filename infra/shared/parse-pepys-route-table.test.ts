import { expect, test } from 'bun:test';
import { parsePepysRouteTable } from './parse-pepys-route-table.ts';
import type { PepysRouteTable } from './parse-pepys-route-table.ts';

test('it returns the routes and the secret variables of a valid table', () => {
  const table: PepysRouteTable = {
    routes: [
      { source: 'github', route: '/webhook/github', reach: 'public' },
      { source: 'telemetry', route: '/v1/logs', reach: 'private' },
    ],
    secretVariables: ['PEPYS_GITHUB_WEBHOOK_SECRET'],
  };

  expect(parsePepysRouteTable(JSON.stringify(table))).toStrictEqual(table);
});

test.each([
  ['a route with no leading slash', { route: 'webhook', reach: 'public' }],
  ['a reach other than public or private', { route: '/webhook', reach: 'tailnet' }],
])('it refuses %s', (_, route) => {
  expect(() =>
    parsePepysRouteTable(
      JSON.stringify({ routes: [{ source: 'github', ...route }], secretVariables: ['A_SECRET'] }),
    ),
  ).toThrowWithMessage(Error, /^deploy\/pepys\/ingest-routes\.json: routes\.0\./u);
});

test('it refuses a secret variable that is not an environment variable name', () => {
  expect(() =>
    parsePepysRouteTable(
      JSON.stringify({
        routes: [{ source: 'github', route: '/webhook', reach: 'public' }],
        secretVariables: ['webhook secret'],
      }),
    ),
  ).toThrowWithMessage(Error, /secretVariables\.0/u);
});

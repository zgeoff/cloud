import { expect, test } from 'bun:test';
import { buildBoxxyPepysAddresses } from './build-boxxy-pepys-addresses.ts';

function setupTest() {
  return {
    routes: [
      { source: 'github', route: '/webhook/github', reach: 'public' as const },
      { source: 'boxxy', route: '/boxxy/facts', reach: 'private' as const },
    ],
    secretVariables: ['PEPYS_BOXXY_SIGNING_SECRET'],
  };
}

test("it points the server at ingest's boxxy route and the API's oRPC route in the cluster", () => {
  const table = setupTest();

  expect(buildBoxxyPepysAddresses(table, 'production')).toStrictEqual({
    ingestUrl: 'http://pepys-ingest.pepys.svc.cluster.local:8080/boxxy/facts',
    apiUrl: 'http://pepys-host.pepys.svc.cluster.local:8081/rpc',
    environment: 'production',
  });
});

test('it refuses a route table with no boxxy route', () => {
  const table = setupTest();

  const withoutBoxxy = {
    ...table,
    routes: table.routes.filter((route) => route.source !== 'boxxy'),
  };

  expect(() => buildBoxxyPepysAddresses(withoutBoxxy, 'production')).toThrowWithMessage(
    Error,
    'stack config "boxxy.pepys" needs the boxxy route in deploy/pepys/ingest-routes.json, which lists none',
  );
});

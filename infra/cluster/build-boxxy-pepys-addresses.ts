import type { PepysRouteTable } from '../shared/parse-pepys-route-table.ts';
import { pepysWorkloads } from '../shared/pepys-workloads.ts';

// the pepys API's oRPC route, under its in-cluster Service URL
const pepysAPIRoute = '/rpc';

// The boxxy server's pepys section: ingest's boxxy route, which the route table copies from the
// deployment, and the API's oRPC route, both at their in-cluster Services
export function buildBoxxyPepysAddresses(
  table: PepysRouteTable,
  environment: string,
): { readonly ingestUrl: string; readonly apiUrl: string; readonly environment: string } {
  const route = table.routes.find((entry) => entry.source === 'boxxy');

  if (route === undefined) {
    throw new Error(
      'stack config "boxxy.pepys" needs the boxxy route in deploy/pepys/ingest-routes.json, which lists none',
    );
  }

  return {
    ingestUrl: `${pepysWorkloads.ingest.url}${route.route}`,
    apiUrl: `${pepysWorkloads.host.url}${pepysAPIRoute}`,
    environment,
  };
}

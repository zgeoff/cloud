import { readFileSync } from 'node:fs';
import { parsePepysRouteTable } from './parse-pepys-route-table.ts';
import type { PepysRouteTable } from './parse-pepys-route-table.ts';

// The table copies the receive routes of deploy/pepys's deployment, so that the Pulumi program,
// which cannot load the plug-ins, opens the tunnel for exactly the routes they mark public.
export function readPepysRouteTable(): PepysRouteTable {
  return parsePepysRouteTable(
    readFileSync(new URL('../../deploy/pepys/ingest-routes.json', import.meta.url), 'utf8'),
  );
}

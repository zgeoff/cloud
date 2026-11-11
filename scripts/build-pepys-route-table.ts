import { z } from 'zod';

// The parts of a pepys deployment that ingest reads at start: each receive path's routes and
// secret, and each pull path's variables. Loose objects, so the check reads a deployment of any
// later @pepys/kit that keeps these fields.
const receivePathSchema = z.looseObject({
  kind: z.literal('receive'),
  route: z.string(),
  ignoredRoutes: z.array(z.string()).optional(),
  check: z.looseObject({ secretEnv: z.string() }),
  reach: z.enum(['public', 'private']).optional(),
});

const pullPathSchema = z.looseObject({
  kind: z.literal('pull'),
  env: z.array(z.string()).optional(),
});

const pathSchema = z.union([receivePathSchema, pullPathSchema]).optional();

const sourceSchema = z.looseObject({
  name: z.string(),
  live: pathSchema,
  recovery: pathSchema,
  backfill: pathSchema,
  resync: pathSchema,
});

const pluginSchema = z.looseObject({ sources: z.array(sourceSchema) });
const deploymentSchema = z.looseObject({ plugins: z.array(pluginSchema) });

interface PepysRoute {
  readonly source: string;
  readonly route: string;
  readonly reach: 'public' | 'private';
}

export interface PepysRouteTable {
  readonly routes: PepysRoute[];
  readonly secretVariables: string[];
}

// The table deploy/pepys/ingest-routes.json must hold: the routes in the order the kit lists them,
// and the variables in the order ingest reads them.
export function buildPepysRouteTable(deployment: unknown): PepysRouteTable {
  const sources = deploymentSchema.parse(deployment).plugins.flatMap((plugin) => plugin.sources);
  const routes: PepysRoute[] = [];
  const secretVariables: string[] = [];

  for (const source of sources) {
    if (source.live?.kind === 'receive') {
      const reach = source.live.reach ?? 'private';

      for (const route of [source.live.route, ...(source.live.ignoredRoutes ?? [])]) {
        routes.push({ source: source.name, route, reach });
      }

      secretVariables.push(source.live.check.secretEnv);
    }

    for (const path of [source.live, source.recovery, source.backfill, source.resync]) {
      if (path?.kind === 'pull') {
        secretVariables.push(...(path.env ?? []));
      }
    }
  }

  return { routes, secretVariables: [...new Set(secretVariables)] };
}

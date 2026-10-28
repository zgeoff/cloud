import { z } from 'zod';

// The first path segment of a preview's model call is its route ID, the imp's name. The grant, the
// route listener and the proxy config all depend on that, so each builds or reads it here.
const routeIDSchema = z.string().regex(/^[a-z0-9][a-z0-9-]*$/u);

export interface ModelRoutePath {
  readonly imp: string;
  readonly path: string;
}

export const modelRoute = {
  idSchema: routeIDSchema,

  // the broker's path filter for the imp, which keeps its model calls on its own route
  buildGrantPaths: (imp: string): readonly string[] => [`/${routeIDSchema.parse(imp)}/**`],

  // null for a path whose first segment is no route ID
  parsePath: (pathname: string): ModelRoutePath | null => {
    const [, routeID = '', ...rest] = pathname.split('/');
    const parsed = routeIDSchema.safeParse(routeID);

    return parsed.success ? { imp: parsed.data, path: `/${rest.join('/')}` } : null;
  },
};

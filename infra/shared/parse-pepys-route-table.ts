import { z } from 'zod';

const routeSchema = z.object({
  source: z.string().min(1),
  route: z.string().regex(/^\/[\w./-]*$/u),
  reach: z.enum(['public', 'private']),
});

const routeTableSchema = z.object({
  routes: z.array(routeSchema).min(1),
  secretVariables: z.array(z.string().regex(/^[A-Z][\dA-Z_]*$/u)).min(1),
});

export type PepysRouteTable = z.output<typeof routeTableSchema>;

export function parsePepysRouteTable(text: string): PepysRouteTable {
  const result = routeTableSchema.safeParse(JSON.parse(text));

  if (!result.success) {
    const issues = result.error.issues.map((issue) => `${issue.path.join('.')} ${issue.message}`);

    throw new Error(`deploy/pepys/ingest-routes.json: ${issues.join('; ')}`);
  }

  return result.data;
}

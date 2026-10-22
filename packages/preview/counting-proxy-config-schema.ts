import { z } from 'zod';
import { modelRoute } from './model-route.ts';

// The config file that nixie's counting proxy reads, as nixie's proxy config schema defines it.
// The service writes each proxy's file through this schema, and the stub proxy in the tests reads
// it through the same one.
export const spendPricesSchema = z.strictObject({
  input: z.number().nonnegative(),
  cache_write: z.number().nonnegative(),
  cache_write_1h: z.number().nonnegative(),
  cached_input: z.number().nonnegative(),
  output: z.number().nonnegative(),
});

const routeSchema = z.strictObject({
  upstream: z.url(),
  model: z.string().min(1),
  prices: spendPricesSchema,
});

export const countingProxyConfigSchema = z.strictObject({
  listen: z.strictObject({ hostname: z.string(), port: z.int().min(0).max(65_535) }),
  store: z.string().min(1),
  limits: z.strictObject({ dollars: z.number().positive() }),
  routes: z.record(modelRoute.idSchema, routeSchema),
});

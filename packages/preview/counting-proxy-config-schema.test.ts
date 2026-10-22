import { expect, test } from 'bun:test';
import { join } from 'node:path';
import { z } from 'zod';
import { countingProxyConfigSchema } from './counting-proxy-config-schema.ts';
import { collectSchemaFields } from './test-utils/collect-schema-fields.ts';

test('it reads a proxy config with one route for an imp', () => {
  const config = {
    listen: { hostname: '127.0.0.1', port: 0 },
    store: '/var/lib/example/spend/pv-0a1b2c3d-7.count.json',
    limits: { dollars: 2 },
    routes: {
      'pv-0a1b2c3d-7': {
        upstream: 'https://models.example.test',
        model: 'model-small',
        prices: { input: 1, cache_write: 1.25, cache_write_1h: 2, cached_input: 0.1, output: 5 },
      },
    },
  };

  expect(countingProxyConfigSchema.safeParse(config).data).toStrictEqual(config);
});

test('it reads the config that nixie counting proxy accepts, field for field', async () => {
  const text = await Bun.file(
    join(import.meta.dir, 'test-utils', 'nixie-counting-proxy-config.yaml'),
  ).text();

  const parsed = countingProxyConfigSchema.safeParse(Bun.YAML.parse(text));

  expect(parsed.data).toStrictEqual({
    listen: { hostname: '127.0.0.1', port: 0 },
    store: '/var/lib/preview/spend/pv-0a1b2c3d-7.count.json',
    limits: { dollars: 2 },
    routes: {
      'pv-0a1b2c3d-7': {
        upstream: 'https://models.example.test',
        model: 'model-small',
        prices: { input: 1, cache_write: 1.25, cache_write_1h: 2, cached_input: 0.1, output: 5 },
      },
    },
  });
});

// nixie's proxy config fields at commit 8a1018c, as cloud writes them: nixie also reads an
// optional token limit and defaults the hostname, and cloud sets the dollar limit and the hostname
test('it writes the fields of nixie proxy config with their types and no others', () => {
  expect(collectSchemaFields(z.toJSONSchema(countingProxyConfigSchema))).toStrictEqual([
    'limits.dollars: number',
    'listen.hostname: string',
    'listen.port: integer',
    'routes.*.model: string',
    'routes.*.prices.cache_write: number',
    'routes.*.prices.cache_write_1h: number',
    'routes.*.prices.cached_input: number',
    'routes.*.prices.input: number',
    'routes.*.prices.output: number',
    'routes.*.upstream: string',
    'store: string',
  ]);
});

test('it refuses a route with no 1-hour cache write price', () => {
  const result = countingProxyConfigSchema.safeParse({
    listen: { hostname: '127.0.0.1', port: 0 },
    store: '/var/lib/example/spend/pv-0a1b2c3d-7.count.json',
    limits: { dollars: 2 },
    routes: {
      'pv-0a1b2c3d-7': {
        upstream: 'https://models.example.test',
        model: 'model-small',
        prices: { input: 1, cache_write: 1.25, cached_input: 0.1, output: 5 },
      },
    },
  });

  expect(result.error?.issues).toPartiallyContain({
    path: ['routes', 'pv-0a1b2c3d-7', 'prices', 'cache_write_1h'],
  });
});

test('it refuses a limit of no dollars', () => {
  const result = countingProxyConfigSchema.safeParse({
    listen: { hostname: '127.0.0.1', port: 0 },
    store: '/var/lib/example/spend/pv-0a1b2c3d-7.count.json',
    limits: { dollars: 0 },
    routes: {
      'pv-0a1b2c3d-7': {
        upstream: 'https://models.example.test',
        model: 'model-small',
        prices: { input: 1, cache_write: 1.25, cache_write_1h: 2, cached_input: 0.1, output: 5 },
      },
    },
  });

  expect(result.error?.issues).toPartiallyContain({ path: ['limits', 'dollars'] });
});

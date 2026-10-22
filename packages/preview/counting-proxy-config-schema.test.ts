import { expect, test } from 'bun:test';
import { countingProxyConfigSchema } from './counting-proxy-config-schema.ts';

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

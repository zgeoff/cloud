import { expect, test } from 'bun:test';
import { renderSpendRefusal } from './render-spend-refusal.ts';

test('it answers a route that no preview holds with a 404 that names the route', async () => {
  const response = renderSpendRefusal({
    kind: 'no-preview',
    pathname: '/pv-0a1b2c3d-7/v1/messages',
  });

  const body: unknown = await response.json();

  expect(response.status).toBe(404);

  expect(body).toStrictEqual({
    type: 'error',
    error: {
      type: 'not_found_error',
      message: 'no preview holds the model route /pv-0a1b2c3d-7/v1/messages',
    },
  });
});

test('it answers a proxy that could not start with a 503', async () => {
  const response = renderSpendRefusal({ kind: 'no-proxy' });

  const body: unknown = await response.json();

  expect(response.status).toBe(503);

  expect(body).toStrictEqual({
    type: 'error',
    error: { type: 'api_error', message: 'the preview service could not start the counting proxy' },
  });
});

test('it answers a proxy that did not answer with a 502', async () => {
  const response = renderSpendRefusal({ kind: 'no-answer' });

  const body: unknown = await response.json();

  expect(response.status).toBe(502);

  expect(body).toStrictEqual({
    type: 'error',
    error: { type: 'api_error', message: 'the counting proxy did not answer' },
  });
});

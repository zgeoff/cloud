import { expect, test } from 'bun:test';
import { HttpResponse, http } from 'msw';
import { checkGatewayImage } from './check-gateway-image.ts';
import { server } from './mocks/node.ts';

test('it finds the image with ghcr’s anonymous pull token', async () => {
  const bearers: (string | null)[] = [];

  server.use(
    http.get('https://ghcr.io/token', (info) => {
      bearers.push(new URL(info.request.url).searchParams.get('scope'));

      return HttpResponse.json({ token: 'ghcr-t1' });
    }),
    http.get('https://ghcr.io/v2/zgeoff/atc-gateway/tags/list', (info) => {
      bearers.push(info.request.headers.get('authorization'));

      return HttpResponse.json({ name: 'zgeoff/atc-gateway', tags: ['1.0.0'] });
    }),
  );

  const line = await checkGatewayImage();

  expect(line).toStrictEqual({ status: 'ok', text: 'image ghcr.io/zgeoff/atc-gateway exists' });
  expect(bearers).toStrictEqual(['repository:zgeoff/atc-gateway:pull', 'Bearer ghcr-t1']);
});

test('it reports the image missing when the tag list answers another status', async () => {
  server.use(
    http.get('https://ghcr.io/token', () => HttpResponse.json({ token: 'ghcr-t1' })),
    http.get(
      'https://ghcr.io/v2/zgeoff/atc-gateway/tags/list',
      () => new HttpResponse(null, { status: 404 }),
    ),
  );

  const line = await checkGatewayImage();

  expect(line).toStrictEqual({ status: 'missing', text: 'image ghcr.io/zgeoff/atc-gateway' });
});

test('it reports the image missing when ghcr hands out no token', async () => {
  server.use(http.get('https://ghcr.io/token', () => HttpResponse.json({ errors: [] })));

  const line = await checkGatewayImage();

  expect(line.status).toBe('missing');
});

test('it reports the image missing when ghcr does not answer', async () => {
  server.use(http.get('https://ghcr.io/token', () => HttpResponse.error()));

  const line = await checkGatewayImage();

  expect(line.status).toBe('missing');
});

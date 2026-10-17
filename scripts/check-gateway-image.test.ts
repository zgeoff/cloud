import { expect, test } from 'bun:test';
import { HttpResponse, http } from 'msw';
import { checkGatewayImage } from './check-gateway-image.ts';
import { server } from './mocks/node.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';

// gh prints the token it holds, as `gh auth token` does once signed in or with GH_TOKEN set
function setupTest() {
  return buildStubRunner((call) =>
    call.argv.join(' ') === 'gh auth token --hostname github.com'
      ? { stdout: 'gh-token-1\n' }
      : undefined,
  );
}

test('it finds the private image with a pull token the GitHub token pays for', async () => {
  const stub = setupTest();
  const seen: (string | null)[] = [];

  server.use(
    http.get('https://ghcr.io/token', (info) => {
      seen.push(
        new URL(info.request.url).searchParams.get('scope'),
        info.request.headers.get('authorization'),
      );

      return HttpResponse.json({ token: 'ghcr-t1' });
    }),
    http.get('https://ghcr.io/v2/zgeoff/atc-gateway/tags/list', (info) => {
      seen.push(info.request.headers.get('authorization'));

      return HttpResponse.json({ name: 'zgeoff/atc-gateway', tags: ['1.0.0'] });
    }),
  );

  const line = await checkGatewayImage(stub.run);

  expect(line).toStrictEqual({ status: 'ok', text: 'image ghcr.io/zgeoff/atc-gateway exists' });

  expect(seen).toStrictEqual([
    'repository:zgeoff/atc-gateway:pull',
    `Basic ${btoa('x:gh-token-1')}`,
    'Bearer ghcr-t1',
  ]);
});

test('it fails, naming the missing credential, without asking ghcr when there is no GitHub token', async () => {
  // gh exits 1 with this message when it holds no token and neither GH_TOKEN nor GITHUB_TOKEN is set
  const stub = buildStubRunner(() => ({
    exitCode: 1,
    stderr: 'no oauth token found for github.com\n',
  }));

  const line = await checkGatewayImage(stub.run);

  expect(line).toStrictEqual({
    status: 'FAIL',
    text: 'image ghcr.io/zgeoff/atc-gateway: no GitHub token to read ghcr.io/zgeoff: set GH_TOKEN, or sign gh in with the read:packages scope',
  });
});

test('it fails when ghcr refuses the GitHub token at the tag list', async () => {
  const stub = setupTest();

  server.use(
    http.get('https://ghcr.io/token', () => HttpResponse.json({ token: 'ghcr-t1' })),
    http.get(
      'https://ghcr.io/v2/zgeoff/atc-gateway/tags/list',
      () => new HttpResponse(null, { status: 403 }),
    ),
  );

  const line = await checkGatewayImage(stub.run);

  expect(line).toStrictEqual({
    status: 'FAIL',
    text: 'image ghcr.io/zgeoff/atc-gateway: ghcr.io refused the GitHub token (403)',
  });
});

test('it fails when ghcr refuses the GitHub token at its token realm', async () => {
  const stub = setupTest();

  server.use(http.get('https://ghcr.io/token', () => new HttpResponse(null, { status: 401 })));

  const line = await checkGatewayImage(stub.run);

  expect(line).toStrictEqual({
    status: 'FAIL',
    text: 'image ghcr.io/zgeoff/atc-gateway: ghcr.io refused the GitHub token (401)',
  });
});

test('it reports the image missing when the tag list answers 404', async () => {
  const stub = setupTest();

  server.use(
    http.get('https://ghcr.io/token', () => HttpResponse.json({ token: 'ghcr-t1' })),
    http.get(
      'https://ghcr.io/v2/zgeoff/atc-gateway/tags/list',
      () => new HttpResponse(null, { status: 404 }),
    ),
  );

  const line = await checkGatewayImage(stub.run);

  expect(line).toStrictEqual({ status: 'missing', text: 'image ghcr.io/zgeoff/atc-gateway' });
});

test('it reports the image missing when ghcr hands out no token', async () => {
  const stub = setupTest();

  server.use(http.get('https://ghcr.io/token', () => HttpResponse.json({ errors: [] })));

  const line = await checkGatewayImage(stub.run);

  expect(line.status).toBe('missing');
});

test('it reports the image missing when ghcr does not answer', async () => {
  const stub = setupTest();

  server.use(http.get('https://ghcr.io/token', () => HttpResponse.error()));

  const line = await checkGatewayImage(stub.run);

  expect(line.status).toBe('missing');
});

import { expect, test } from 'bun:test';
import { HttpResponse, http } from 'msw';
import { checkGatewayRoute } from './check-gateway-route.ts';
import { server } from './mocks/node.ts';
import { buildStubGetent } from './test-utils/build-stub-getent.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';

test('it passes the route when its metadata answers 200', async () => {
  const stub = buildStubRunner(buildStubGetent({ 'atc.geoff.cloud': '104.21.32.1' }));

  server.use(
    http.get('https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp', () =>
      HttpResponse.json({ resource: 'https://atc.geoff.cloud/mcp' }),
    ),
  );

  const line = await checkGatewayRoute(stub.run);

  expect(line).toStrictEqual({
    status: 'ok',
    text: 'atc.geoff.cloud protected-resource metadata: 200',
  });
});

test('it reads a redirect as its own status, not the target’s', async () => {
  const stub = buildStubRunner(buildStubGetent({ 'atc.geoff.cloud': '104.21.32.1' }));

  server.use(
    http.get(
      'https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp',
      () =>
        new HttpResponse(null, { status: 302, headers: { location: 'https://login.invalid/' } }),
    ),
  );

  const line = await checkGatewayRoute(stub.run);

  expect(line).toStrictEqual({
    status: 'FAIL',
    text: 'atc.geoff.cloud protected-resource metadata: 302',
  });
});

test('it reports the DNS record missing, and asks no route, when the name does not resolve', async () => {
  const stub = buildStubRunner(buildStubGetent({}));

  const line = await checkGatewayRoute(stub.run);

  expect(line).toStrictEqual({ status: 'missing', text: 'DNS record atc.geoff.cloud' });
});

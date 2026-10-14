// MSW's resolver info carries a Request, which has no readonly form
/* oxlint-disable typescript/prefer-readonly-parameter-types */
import { expect, test } from 'bun:test';
import { HttpResponse, http, passthrough } from 'msw';
import { server } from './mocks/node.ts';
import { tryReadManifestDigest } from './try-read-manifest-digest.ts';

test('it reads the digest a tag names, asking for an index or a manifest in either media type', async () => {
  const accepts: (string | null)[] = [];

  server.use(
    http.head('https://ghcr.io/v2/zgeoff/backup/manifests/1.0.0-r2', (info) => {
      accepts.push(info.request.headers.get('accept'));

      return new HttpResponse(null, {
        status: 200,
        headers: { 'docker-content-digest': `sha256:${'1'.repeat(64)}` },
      });
    }),
  );

  const answer = await tryReadManifestDigest('ghcr.io/zgeoff/backup', '1.0.0-r2');

  expect(answer).toStrictEqual({ digest: `sha256:${'1'.repeat(64)}` });

  expect(accepts).toStrictEqual([
    'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json',
  ]);
});

test('it reads a manifest by its digest', async () => {
  server.use(
    http.head(
      `https://gcr.io/v2/distroless/cc/manifests/sha256:${'6'.repeat(64)}`,
      () =>
        new HttpResponse(null, {
          status: 200,
          headers: { 'docker-content-digest': `sha256:${'6'.repeat(64)}` },
        }),
    ),
  );

  const answer = await tryReadManifestDigest('gcr.io/distroless/cc', `sha256:${'6'.repeat(64)}`);

  expect(answer).toStrictEqual({ digest: `sha256:${'6'.repeat(64)}` });
});

test('it answers missing when the registry serves no such manifest', async () => {
  server.use(
    http.head(`https://gcr.io/v2/distroless/cc/manifests/sha256:${'6'.repeat(64)}`, () =>
      HttpResponse.json(
        { errors: [{ code: 'MANIFEST_UNKNOWN', message: 'manifest unknown' }] },
        { status: 404 },
      ),
    ),
  );

  const answer = await tryReadManifestDigest('gcr.io/distroless/cc', `sha256:${'6'.repeat(64)}`);

  expect(answer).toStrictEqual({ missing: true });
});

test("it takes an anonymous pull token from the registry's Bearer challenge", async () => {
  server.use(
    http.head('https://registry-1.docker.io/v2/example/builder/manifests/2.30.0', (info) =>
      info.request.headers.get('authorization') === 'Bearer pull-token-7'
        ? new HttpResponse(null, {
            status: 200,
            headers: { 'docker-content-digest': `sha256:${'4'.repeat(64)}` },
          })
        : new HttpResponse(null, {
            status: 401,
            headers: {
              'www-authenticate':
                'Bearer realm="https://auth.docker.io/token",service="registry.docker.io",scope="repository:example/builder:pull"',
            },
          }),
    ),
    http.get('https://auth.docker.io/token', (info) => {
      const query = new URL(info.request.url).searchParams;

      return query.get('service') === 'registry.docker.io' &&
        query.get('scope') === 'repository:example/builder:pull'
        ? HttpResponse.json({ token: 'pull-token-7', access_token: 'pull-token-7' })
        : HttpResponse.json({ errors: [{ code: 'DENIED' }] }, { status: 403 });
    }),
  );

  const answer = await tryReadManifestDigest('example/builder', '2.30.0');

  expect(answer).toStrictEqual({ digest: `sha256:${'4'.repeat(64)}` });
});

test("it pays for ghcr.io's pull token with the GitHub token, which reads a private package", async () => {
  const realmAuthorizations: (string | null)[] = [];

  server.use(
    http.head('https://ghcr.io/v2/zgeoff/atc-gateway/manifests/2.27.0', (info) =>
      info.request.headers.get('authorization') === 'Bearer pull-token-9'
        ? new HttpResponse(null, {
            status: 200,
            headers: { 'docker-content-digest': `sha256:${'6'.repeat(64)}` },
          })
        : new HttpResponse(null, {
            status: 401,
            headers: {
              'www-authenticate':
                'Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:zgeoff/atc-gateway:pull"',
            },
          }),
    ),
    http.get('https://ghcr.io/token', (info) => {
      const authorization = info.request.headers.get('authorization');

      realmAuthorizations.push(authorization);

      return authorization === `Basic ${btoa('x:gh-token-1')}`
        ? HttpResponse.json({ token: 'pull-token-9' })
        : HttpResponse.json({ token: 'pull-token-0' });
    }),
  );

  const answer = await tryReadManifestDigest('ghcr.io/zgeoff/atc-gateway', '2.27.0', 'gh-token-1');

  expect(answer).toStrictEqual({ digest: `sha256:${'6'.repeat(64)}` });
  expect(realmAuthorizations).toStrictEqual([`Basic ${btoa('x:gh-token-1')}`]);
});

test("it never sends the GitHub token to another registry's realm", async () => {
  const realmAuthorizations: (string | null)[] = [];

  server.use(
    http.head('https://registry-1.docker.io/v2/example/builder/manifests/2.30.0', (info) =>
      info.request.headers.get('authorization') === 'Bearer pull-token-8'
        ? new HttpResponse(null, {
            status: 200,
            headers: { 'docker-content-digest': `sha256:${'7'.repeat(64)}` },
          })
        : new HttpResponse(null, {
            status: 401,
            headers: {
              'www-authenticate':
                'Bearer realm="https://auth.docker.io/token",service="registry.docker.io",scope="repository:example/builder:pull"',
            },
          }),
    ),
    http.get('https://auth.docker.io/token', (info) => {
      realmAuthorizations.push(info.request.headers.get('authorization'));

      return HttpResponse.json({ token: 'pull-token-8' });
    }),
  );

  const answer = await tryReadManifestDigest('example/builder', '2.30.0', 'gh-token-1');

  expect(answer).toStrictEqual({ digest: `sha256:${'7'.repeat(64)}` });
  expect(realmAuthorizations).toStrictEqual([null]);
});

test('it says the credential cannot read a manifest the registry refuses with its token', async () => {
  server.use(
    http.head(
      'https://ghcr.io/v2/zgeoff/atc-gateway/manifests/2.27.0',
      () => new HttpResponse(null, { status: 403 }),
    ),
  );

  const answer = await tryReadManifestDigest('ghcr.io/zgeoff/atc-gateway', '2.27.0', 'gh-token-1');

  expect(answer).toStrictEqual({
    error: 'the registry answered 403: the credential cannot read it',
  });
});

test("it asks Docker Hub's library namespace for an official image", async () => {
  server.use(
    http.head(
      'https://registry-1.docker.io/v2/library/alpine/manifests/3.20',
      () =>
        new HttpResponse(null, {
          status: 200,
          headers: { 'docker-content-digest': `sha256:${'5'.repeat(64)}` },
        }),
    ),
  );

  const answer = await tryReadManifestDigest('alpine', '3.20');

  expect(answer).toStrictEqual({ digest: `sha256:${'5'.repeat(64)}` });
});

test('it answers with the status when the registry answers with an error', async () => {
  server.use(
    http.head(
      'https://gcr.io/v2/distroless/cc/manifests/nonroot',
      () => new HttpResponse(null, { status: 503 }),
    ),
  );

  const answer = await tryReadManifestDigest('gcr.io/distroless/cc', 'nonroot');

  expect(answer).toStrictEqual({ error: 'the registry answered 503' });
});

test('it answers with the error when it cannot reach the registry', async () => {
  server.use(http.head('https://127.0.0.1:1/*', () => passthrough()));

  const answer = await tryReadManifestDigest('127.0.0.1:1/zgeoff/backup', '1.0.0');

  expect(answer).toStrictEqual({ error: expect.toSatisfy((text: string) => text !== '') });
});

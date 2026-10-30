import { expect, mock, onTestFinished, test } from 'bun:test';
import { appendFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { HttpResponse, http } from 'msw';
import { server } from '../mocks/node.ts';
import { tryReadManifestDigest } from '../try-read-manifest-digest.ts';
import { runDecideGatewayPublish } from './run-decide-gateway-publish.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'decide-gateway-publish-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const checkout = join(directory, 'checkout');
  const output = join(directory, 'output');
  const summary = join(directory, 'summary');

  await mkdir(join(checkout, 'images', 'atc-gateway'), { recursive: true });
  await mkdir(join(checkout, 'infra'));
  await writeFile(output, '');
  await writeFile(summary, '');

  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  const dependencies = {
    readText: (path: string) => readFile(path, 'utf8'),
    appendText: (path: string, text: string) => appendFile(path, text),
    readManifestDigest: tryReadManifestDigest,
    printOut,
    printErr,
  };

  return { checkout, output, summary, printOut, printErr, dependencies };
}

test('it publishes for a push to main whose gateway tag the registry lacks', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.checkout, 'images', 'atc-gateway', 'versions.env'),
    'ATC_RELEASE=@zgeoff/atc@7.2.0\nGATEWAY_IMAGE_TAG=7.2.0\nBACKUP_IMAGE_TAG=2.24.0-r2\n',
  );

  await writeFile(
    join(ctx.checkout, 'infra', 'Pulumi.prod.yaml'),
    `config:\n  geoff-cloud:atcGateway:\n    image: ghcr.io/zgeoff/atc-gateway:7.1.0@sha256:${'1'.repeat(64)}\n    backupImage: ghcr.io/zgeoff/atc-gateway-backup:2.24.0-r2@sha256:${'3'.repeat(64)}\n`,
  );

  server.use(
    http.head(
      'https://ghcr.io/v2/zgeoff/atc-gateway/manifests/7.2.0',
      () => new HttpResponse(null, { status: 404 }),
    ),
    http.head(
      'https://ghcr.io/v2/zgeoff/atc-gateway-backup/manifests/2.24.0-r2',
      () =>
        new HttpResponse(null, {
          status: 200,
          headers: { 'docker-content-digest': `sha256:${'3'.repeat(64)}` },
        }),
    ),
  );

  const status = await runDecideGatewayPublish({
    ...ctx.dependencies,
    env: {
      EVENT: 'push',
      REF: 'refs/heads/main',
      GITHUB_OUTPUT: ctx.output,
      GITHUB_STEP_SUMMARY: ctx.summary,
    },
    cwd: ctx.checkout,
  });

  const output = await readFile(ctx.output, 'utf8');
  const summary = await readFile(ctx.summary, 'utf8');

  expect(status).toBe(0);
  expect(output).toBe('publish=true\n');
  expect(summary).toBe('publish: the registry lacks ghcr.io/zgeoff/atc-gateway:7.2.0\n');
  expect(ctx.printErr.mock.calls).toStrictEqual([]);
});

test('it skips a push to main whose tags the registry holds and the stack config pins', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.checkout, 'images', 'atc-gateway', 'versions.env'),
    'GATEWAY_IMAGE_TAG=7.1.0\nBACKUP_IMAGE_TAG=2.24.0-r2\n',
  );

  await writeFile(
    join(ctx.checkout, 'infra', 'Pulumi.prod.yaml'),
    `config:\n  geoff-cloud:atcGateway:\n    image: ghcr.io/zgeoff/atc-gateway:7.1.0@sha256:${'2'.repeat(64)}\n    backupImage: ghcr.io/zgeoff/atc-gateway-backup:2.24.0-r2@sha256:${'3'.repeat(64)}\n`,
  );

  server.use(
    http.head(
      'https://ghcr.io/v2/zgeoff/atc-gateway/manifests/7.1.0',
      () =>
        new HttpResponse(null, {
          status: 200,
          headers: { 'docker-content-digest': `sha256:${'2'.repeat(64)}` },
        }),
    ),
    http.head(
      'https://ghcr.io/v2/zgeoff/atc-gateway-backup/manifests/2.24.0-r2',
      () =>
        new HttpResponse(null, {
          status: 200,
          headers: { 'docker-content-digest': `sha256:${'3'.repeat(64)}` },
        }),
    ),
  );

  const status = await runDecideGatewayPublish({
    ...ctx.dependencies,
    env: {
      EVENT: 'push',
      REF: 'refs/heads/main',
      GITHUB_OUTPUT: ctx.output,
      GITHUB_STEP_SUMMARY: ctx.summary,
    },
    cwd: ctx.checkout,
  });

  const output = await readFile(ctx.output, 'utf8');

  expect(status).toBe(0);
  expect(output).toBe('publish=false\n');

  expect(ctx.printOut.mock.calls).toStrictEqual([
    ['skip: the registry holds every pinned tag, and the stack config pins it\n'],
  ]);
});

// the re-run of a release whose pushes passed and whose pin pull request step failed
test('it publishes again for a re-run whose pushed tags the stack config does not pin yet', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.checkout, 'images', 'atc-gateway', 'versions.env'),
    'GATEWAY_IMAGE_TAG=7.2.0\nBACKUP_IMAGE_TAG=2.24.0-r2\n',
  );

  await writeFile(
    join(ctx.checkout, 'infra', 'Pulumi.prod.yaml'),
    `config:\n  geoff-cloud:atcGateway:\n    image: ghcr.io/zgeoff/atc-gateway:7.1.0@sha256:${'1'.repeat(64)}\n    backupImage: ghcr.io/zgeoff/atc-gateway-backup:2.24.0-r2@sha256:${'3'.repeat(64)}\n`,
  );

  server.use(
    http.head(
      'https://ghcr.io/v2/zgeoff/atc-gateway/manifests/7.2.0',
      () =>
        new HttpResponse(null, {
          status: 200,
          headers: { 'docker-content-digest': `sha256:${'2'.repeat(64)}` },
        }),
    ),
    http.head(
      'https://ghcr.io/v2/zgeoff/atc-gateway-backup/manifests/2.24.0-r2',
      () =>
        new HttpResponse(null, {
          status: 200,
          headers: { 'docker-content-digest': `sha256:${'3'.repeat(64)}` },
        }),
    ),
  );

  const status = await runDecideGatewayPublish({
    ...ctx.dependencies,
    env: {
      EVENT: 'push',
      REF: 'refs/heads/main',
      GITHUB_OUTPUT: ctx.output,
      GITHUB_STEP_SUMMARY: ctx.summary,
    },
    cwd: ctx.checkout,
  });

  const output = await readFile(ctx.output, 'utf8');

  expect(status).toBe(0);
  expect(output).toBe('publish=true\n');

  expect(ctx.printOut.mock.calls).toStrictEqual([
    ['publish: the stack config does not pin ghcr.io/zgeoff/atc-gateway:7.2.0 yet\n'],
  ]);
});

test("it reads a private package's tags with the GitHub token it is given", async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.checkout, 'images', 'atc-gateway', 'versions.env'),
    'GATEWAY_IMAGE_TAG=7.1.0\nBACKUP_IMAGE_TAG=2.24.0-r2\n',
  );

  await writeFile(
    join(ctx.checkout, 'infra', 'Pulumi.prod.yaml'),
    `config:\n  geoff-cloud:atcGateway:\n    image: ghcr.io/zgeoff/atc-gateway:7.1.0@sha256:${'2'.repeat(64)}\n    backupImage: ghcr.io/zgeoff/atc-gateway-backup:2.24.0-r2@sha256:${'3'.repeat(64)}\n`,
  );

  server.use(
    http.head('https://ghcr.io/v2/zgeoff/:name/manifests/:tag', (info) =>
      info.request.headers.get('authorization') === 'Bearer pull-token-5'
        ? new HttpResponse(null, {
            status: 200,
            headers: { 'docker-content-digest': `sha256:${'4'.repeat(64)}` },
          })
        : new HttpResponse(null, {
            status: 401,
            headers: {
              'www-authenticate': `Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:zgeoff/${String(info.params['name'])}:pull"`,
            },
          }),
    ),

    // ghcr.io refuses a pull token for a private package to an anonymous caller
    http.get('https://ghcr.io/token', (info) =>
      info.request.headers.get('authorization') === `Basic ${btoa('x:gh-token-7')}`
        ? HttpResponse.json({ token: 'pull-token-5' })
        : HttpResponse.json({ errors: [{ code: 'DENIED' }] }, { status: 403 }),
    ),
  );

  const status = await runDecideGatewayPublish({
    ...ctx.dependencies,
    env: {
      EVENT: 'push',
      REF: 'refs/heads/main',
      GH_TOKEN: 'gh-token-7',
      GITHUB_OUTPUT: ctx.output,
      GITHUB_STEP_SUMMARY: ctx.summary,
    },
    cwd: ctx.checkout,
  });

  const output = await readFile(ctx.output, 'utf8');

  expect(status).toBe(0);
  expect(output).toBe('publish=false\n');
  expect(ctx.printErr.mock.calls).toStrictEqual([]);
});

test('it fails a push when the registry cannot answer for a tag, and writes no output', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.checkout, 'images', 'atc-gateway', 'versions.env'),
    'GATEWAY_IMAGE_TAG=7.2.0\nBACKUP_IMAGE_TAG=2.24.0-r2\n',
  );

  await writeFile(
    join(ctx.checkout, 'infra', 'Pulumi.prod.yaml'),
    `config:\n  geoff-cloud:atcGateway:\n    image: ghcr.io/zgeoff/atc-gateway:7.1.0@sha256:${'1'.repeat(64)}\n    backupImage: ghcr.io/zgeoff/atc-gateway-backup:2.24.0-r2@sha256:${'3'.repeat(64)}\n`,
  );

  server.use(
    http.head(
      'https://ghcr.io/v2/zgeoff/atc-gateway/manifests/7.2.0',
      () => new HttpResponse(null, { status: 404 }),
    ),
    http.head(
      'https://ghcr.io/v2/zgeoff/atc-gateway-backup/manifests/2.24.0-r2',
      () => new HttpResponse(null, { status: 503 }),
    ),
  );

  const status = await runDecideGatewayPublish({
    ...ctx.dependencies,
    env: {
      EVENT: 'push',
      REF: 'refs/heads/main',
      GITHUB_OUTPUT: ctx.output,
      GITHUB_STEP_SUMMARY: ctx.summary,
    },
    cwd: ctx.checkout,
  });

  const output = await readFile(ctx.output, 'utf8');

  expect(status).toBe(1);
  expect(output).toBe('');

  expect(ctx.printErr.mock.calls).toStrictEqual([
    [
      'unknown: cannot tell whether a pinned tag is published: ghcr.io/zgeoff/atc-gateway-backup:2.24.0-r2 (the registry answered 503)\n',
    ],
  ]);
});

test('it fails a push whose pins set no backup tag', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.checkout, 'images', 'atc-gateway', 'versions.env'),
    'GATEWAY_IMAGE_TAG=7.2.0\n',
  );

  await writeFile(join(ctx.checkout, 'infra', 'Pulumi.prod.yaml'), 'config: {}\n');

  const status = await runDecideGatewayPublish({
    ...ctx.dependencies,
    env: {
      EVENT: 'push',
      REF: 'refs/heads/main',
      GITHUB_OUTPUT: ctx.output,
      GITHUB_STEP_SUMMARY: ctx.summary,
    },
    cwd: ctx.checkout,
  });

  expect(status).toBe(1);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['images/atc-gateway/versions.env sets no BACKUP_IMAGE_TAG\n'],
  ]);
});

test('it never publishes for a pull request, and reads neither the pins nor the registry', async () => {
  const ctx = await setupTest();

  const status = await runDecideGatewayPublish({
    ...ctx.dependencies,
    env: {
      EVENT: 'pull_request',
      REF: 'refs/pull/412/merge',
      GITHUB_OUTPUT: ctx.output,
      GITHUB_STEP_SUMMARY: ctx.summary,
    },
    cwd: '/nonexistent',
  });

  const output = await readFile(ctx.output, 'utf8');

  expect(status).toBe(0);
  expect(output).toBe('publish=false\n');
});

test('it fails without the runner output file', async () => {
  const ctx = await setupTest();

  const status = await runDecideGatewayPublish({
    ...ctx.dependencies,
    env: { EVENT: 'push', REF: 'refs/heads/main', GITHUB_STEP_SUMMARY: ctx.summary },
    cwd: '/nonexistent',
  });

  expect(status).toBe(2);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['GITHUB_OUTPUT must be set, as the workflow sets it\n'],
  ]);
});

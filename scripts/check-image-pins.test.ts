// MSW's resolver info carries a Request, which has no readonly form
/* oxlint-disable typescript/prefer-readonly-parameter-types */
import { expect, mock, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { HttpResponse, http, passthrough } from 'msw';
import { checkImagePins } from './check-image-pins.ts';
import { server } from './mocks/node.ts';

async function setupTest() {
  const root = await mkdtemp(join(tmpdir(), 'check-image-pins-'));

  onTestFinished(() => rm(root, { recursive: true, force: true }));

  // every pin file it reads, empty, since a missing one fails the check
  await Promise.all(
    [
      'infra',
      'images/atc-gateway',
      'images/agent',
      'deploy/nixie',
      'nixos/hosts/geoffcloud',
      'scripts',
    ].map((directory) => mkdir(join(root, directory), { recursive: true })),
  );

  await Promise.all(
    [
      'infra/Pulumi.prod.yaml',
      'images/atc-gateway/versions.env',
      'images/atc-gateway/restore-job.yaml',
      'images/agent/Dockerfile',
      'deploy/nixie/restore-job.yaml',
      'nixos/hosts/geoffcloud/configuration.nix',
      'scripts/nix-image.sh',
    ].map((file) => writeFile(join(root, file), '')),
  );

  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  return { root, printOut, printErr };
}

test('it passes when every tag resolves to its pinned digest, asking once for a pin two files hold', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'infra', 'Pulumi.prod.yaml'),
    `config:
  geoff-cloud:atcGateway:
    backupImage: ghcr.io/zgeoff/backup:1.0.0-r2@sha256:${'1'.repeat(64)}
`,
  );

  await writeFile(
    join(ctx.root, 'images', 'atc-gateway', 'restore-job.yaml'),
    `          image: ghcr.io/zgeoff/backup:1.0.0-r2@sha256:${'1'.repeat(64)}\n`,
  );

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

  const exitCode = await checkImagePins({
    args: [ctx.root],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(0);

  expect(ctx.printOut).toHaveBeenCalledExactlyOnceWith(
    'check-image-pins: 2 pins of 1 tags agree with their registries\n',
  );

  expect(ctx.printErr).not.toHaveBeenCalled();

  expect(accepts).toStrictEqual([
    'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json',
  ]);
});

test('it fails a pin whose tag names another digest at the registry', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'images', 'agent', 'Dockerfile'),
    `FROM ghcr.io/zgeoff/base:2.0.0@sha256:${'2'.repeat(64)}\n`,
  );

  server.use(
    http.head(
      'https://ghcr.io/v2/zgeoff/base/manifests/2.0.0',
      () =>
        new HttpResponse(null, {
          status: 200,
          headers: { 'docker-content-digest': `sha256:${'3'.repeat(64)}` },
        }),
    ),
  );

  const exitCode = await checkImagePins({
    args: [ctx.root],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    `check-image-pins: images/agent/Dockerfile: ghcr.io/zgeoff/base:2.0.0 pins sha256:${'2'.repeat(64)}, but the registry's 2.0.0 is sha256:${'3'.repeat(64)}\n`,
  );

  expect(ctx.printOut).not.toHaveBeenCalled();
});

test("it takes an anonymous pull token from the registry's Bearer challenge", async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'scripts', 'nix-image.sh'),
    `NIX_IMAGE='example/builder:2.30.0@sha256:${'4'.repeat(64)}'\n`,
  );

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

  const exitCode = await checkImagePins({
    args: [ctx.root],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(0);

  expect(ctx.printOut).toHaveBeenCalledExactlyOnceWith(
    'check-image-pins: 1 pins of 1 tags agree with their registries\n',
  );

  expect(ctx.printErr).not.toHaveBeenCalled();
});

test("it asks Docker Hub's library namespace for an official image's tag", async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'images', 'atc-gateway', 'versions.env'),
    `RESTIC_IMAGE=alpine:3.20@sha256:${'5'.repeat(64)}\n`,
  );

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

  const exitCode = await checkImagePins({
    args: [ctx.root],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(0);

  expect(ctx.printOut).toHaveBeenCalledExactlyOnceWith(
    'check-image-pins: 1 pins of 1 tags agree with their registries\n',
  );
});

test('it fails a pin whose registry answers with an error', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'nixos', 'hosts', 'geoffcloud', 'configuration.nix'),
    `    image = "gcr.io/distroless/cc:nonroot@sha256:${'6'.repeat(64)}";\n`,
  );

  server.use(
    http.head(
      'https://gcr.io/v2/distroless/cc/manifests/nonroot',
      () => new HttpResponse(null, { status: 503 }),
    ),
  );

  const exitCode = await checkImagePins({
    args: [ctx.root],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    "check-image-pins: nixos/hosts/geoffcloud/configuration.nix: cannot read gcr.io/distroless/cc:nonroot's digest: the registry answered 503\n",
  );

  expect(ctx.printOut).not.toHaveBeenCalled();
});

test('it fails a pin whose registry it cannot reach', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'deploy', 'nixie', 'restore-job.yaml'),
    `          image: 127.0.0.1:1/zgeoff/backup:1.0.0@sha256:${'7'.repeat(64)}\n`,
  );

  server.use(http.head('https://127.0.0.1:1/*', () => passthrough()));

  const exitCode = await checkImagePins({
    args: [ctx.root],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    expect.toSatisfy((text: string) =>
      /^check-image-pins: deploy\/nixie\/restore-job\.yaml: cannot read 127\.0\.0\.1:1\/zgeoff\/backup:1\.0\.0's digest: .+\n$/u.test(
        text,
      ),
    ),
  );

  expect(ctx.printOut).not.toHaveBeenCalled();
});

test('it fails, naming the file, when a pin file is missing', async () => {
  const ctx = await setupTest();

  await rm(join(ctx.root, 'scripts', 'nix-image.sh'));

  const exitCode = await checkImagePins({
    args: [ctx.root],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'check-image-pins: cannot read scripts/nix-image.sh\n',
  );
});

test('it prints its usage and exits 2 for more than one argument', async () => {
  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  const exitCode = await checkImagePins({ args: ['one', 'two'], printOut, printErr });

  expect(exitCode).toBe(2);
  expect(printErr).toHaveBeenCalledExactlyOnceWith('usage: check-image-pins.ts [repo root]\n');
});

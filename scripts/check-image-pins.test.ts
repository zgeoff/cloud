import { expect, mock, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { HttpResponse, http } from 'msw';
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

test('it passes when a release tag names its pinned digest, asking once for a pin two files hold', async () => {
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

  let requests = 0;

  server.use(
    http.head('https://ghcr.io/v2/zgeoff/backup/manifests/1.0.0-r2', () => {
      requests += 1;

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
    'check-image-pins: 2 pins hold: 1 release tags name their pinned digests, and 0 upstream digests are still served\n',
  );

  expect(ctx.printErr).not.toHaveBeenCalled();
  expect(requests).toBe(1);
});

test('it fails a release pin whose tag names another digest at the registry', async () => {
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

test('it fails a release pin whose tag the registry does not have', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'images', 'agent', 'Dockerfile'),
    `FROM ghcr.io/zgeoff/base:2.0.0@sha256:${'2'.repeat(64)}\n`,
  );

  server.use(
    http.head('https://ghcr.io/v2/zgeoff/base/manifests/2.0.0', () =>
      HttpResponse.json(
        { errors: [{ code: 'MANIFEST_UNKNOWN', message: 'manifest unknown' }] },
        { status: 404 },
      ),
    ),
  );

  const exitCode = await checkImagePins({
    args: [ctx.root],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'check-image-pins: images/agent/Dockerfile: ghcr.io/zgeoff/base:2.0.0: the registry has no tag 2.0.0\n',
  );
});

test('it passes an upstream pin whose tag moved, while the registry still serves its digest', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'images', 'atc-gateway', 'versions.env'),
    `BASE_IMAGE=gcr.io/distroless/cc:nonroot@sha256:${'6'.repeat(64)}\n`,
  );

  // the publisher rebuilt nonroot, so the tag names a newer digest than the pin
  server.use(
    http.head(
      'https://gcr.io/v2/distroless/cc/manifests/nonroot',
      () =>
        new HttpResponse(null, {
          status: 200,
          headers: { 'docker-content-digest': `sha256:${'8'.repeat(64)}` },
        }),
    ),
    http.head(
      `https://gcr.io/v2/distroless/cc/manifests/sha256:${'6'.repeat(64)}`,
      () =>
        new HttpResponse(null, {
          status: 200,
          headers: { 'docker-content-digest': `sha256:${'6'.repeat(64)}` },
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
    'check-image-pins: 1 pins hold: 0 release tags name their pinned digests, and 1 upstream digests are still served\n',
  );

  expect(ctx.printErr).not.toHaveBeenCalled();
});

test('it fails an upstream pin whose digest the registry no longer serves', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'images', 'atc-gateway', 'versions.env'),
    `BASE_IMAGE=gcr.io/distroless/cc:nonroot@sha256:${'6'.repeat(64)}\n`,
  );

  server.use(
    http.head(`https://gcr.io/v2/distroless/cc/manifests/sha256:${'6'.repeat(64)}`, () =>
      HttpResponse.json(
        { errors: [{ code: 'MANIFEST_UNKNOWN', message: 'manifest unknown' }] },
        { status: 404 },
      ),
    ),
  );

  const exitCode = await checkImagePins({
    args: [ctx.root],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    `check-image-pins: images/atc-gateway/versions.env: gcr.io/distroless/cc:nonroot pins sha256:${'6'.repeat(64)}, which the registry no longer serves\n`,
  );

  expect(ctx.printOut).not.toHaveBeenCalled();
});

test('it fails a pin whose registry answers with an error', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'nixos', 'hosts', 'geoffcloud', 'configuration.nix'),
    `    image = "gcr.io/distroless/cc:nonroot@sha256:${'6'.repeat(64)}";\n`,
  );

  server.use(
    http.head(
      `https://gcr.io/v2/distroless/cc/manifests/sha256:${'6'.repeat(64)}`,
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
    `check-image-pins: nixos/hosts/geoffcloud/configuration.nix: gcr.io/distroless/cc:nonroot: cannot read gcr.io/distroless/cc@sha256:${'6'.repeat(64)}: the registry answered 503\n`,
  );

  expect(ctx.printOut).not.toHaveBeenCalled();
});

test('it fails a digest with an extra hex digit, without asking the registry', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'images', 'agent', 'Dockerfile'),
    `# the base image\nFROM ghcr.io/zgeoff/base:2.0.0@sha256:${'2'.repeat(65)}\n`,
  );

  const exitCode = await checkImagePins({
    args: [ctx.root],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    `check-image-pins: images/agent/Dockerfile:2: ghcr.io/zgeoff/base:2.0.0@sha256:${'2'.repeat(65)} is not <name>:<tag>@sha256:<64 hex digits>\n`,
  );

  expect(ctx.printOut).not.toHaveBeenCalled();
});

test('it fails an image reference whose digest was removed', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'infra', 'Pulumi.prod.yaml'),
    `config:
  geoff-cloud:atcGateway:
    image: ghcr.io/zgeoff/gateway:3.1.0
`,
  );

  const exitCode = await checkImagePins({
    args: [ctx.root],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'check-image-pins: infra/Pulumi.prod.yaml:3: ghcr.io/zgeoff/gateway:3.1.0 pins no digest\n',
  );

  expect(ctx.printOut).not.toHaveBeenCalled();
});

test('it fails a digest on a line that holds no image reference', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'scripts', 'nix-image.sh'),
    `RUNNER=example/runner:1.0.0@sha256:${'4'.repeat(64)}\n`,
  );

  const exitCode = await checkImagePins({
    args: [ctx.root],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    `check-image-pins: scripts/nix-image.sh:1: a digest outside an image reference: RUNNER=example/runner:1.0.0@sha256:${'4'.repeat(64)}\n`,
  );
});

test('it reads a quoted Nix image and a tag-only key, which is not an image reference', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'nixos', 'hosts', 'geoffcloud', 'configuration.nix'),
    `    image = "example.org:5000/team/host:1.0.0@sha256:${'5'.repeat(64)}";\n`,
  );

  await writeFile(
    join(ctx.root, 'images', 'atc-gateway', 'versions.env'),
    'GATEWAY_IMAGE_TAG=4.0.0\n',
  );

  server.use(
    http.head(
      `https://example.org:5000/v2/team/host/manifests/sha256:${'5'.repeat(64)}`,
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
    'check-image-pins: 1 pins hold: 0 release tags name their pinned digests, and 1 upstream digests are still served\n',
  );
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

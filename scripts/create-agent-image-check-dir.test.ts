import { expect, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { HttpResponse, http } from 'msw';
import { createAgentImageCheckDir } from './create-agent-image-check-dir.ts';
import { server } from './mocks/node.ts';
import { buildRealProgramHandler } from './test-utils/build-real-program-handler.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';
import { startStubGitleaksRelease } from './test-utils/start-stub-gitleaks-release.ts';

// a repo with the gitleaks config the check copies, and a work directory the caller owns
async function setupTest() {
  const dir = await mkdtemp(join(tmpdir(), 'create-agent-image-check-dir-'));

  onTestFinished(() => rm(dir, { recursive: true, force: true }));

  const repo = join(dir, 'repo');
  const work = join(dir, 'work');

  await mkdir(join(repo, 'scripts'), { recursive: true });
  await mkdir(work);
  await writeFile(join(repo, 'scripts/agent-image-gitleaks.toml'), '[extend]\nuseDefault = true\n');

  const stub = buildStubRunner(buildRealProgramHandler(['tar']));

  return { repo, work, stub, io: { run: stub.run, printOut: () => {}, printErr: () => {} } };
}

test('it holds the pinned gitleaks binary and the gitleaks config', async () => {
  const ctx = await setupTest();
  const sum = await startStubGitleaksRelease('8.30.1', 'fake gitleaks\n');

  const dir = await createAgentImageCheckDir(ctx.io, {
    work: ctx.work,
    repo: ctx.repo,
    pins: { GITLEAKS_VERSION: '8.30.1', GITLEAKS_SHA256: sum },
  });

  const files = await readdir(dir);
  const binary = await readFile(join(dir, 'gitleaks'), 'utf8');
  const config = await readFile(join(dir, 'gitleaks.toml'), 'utf8');

  expect(dir).toBe(join(ctx.work, 'agent-image-check'));
  expect(files.toSorted()).toStrictEqual(['gitleaks', 'gitleaks.toml']);
  expect(binary).toBe('fake gitleaks\n');
  expect(config).toBe('[extend]\nuseDefault = true\n');
});

test('it stops before extracting a tarball whose sum the Dockerfile does not pin', async () => {
  const ctx = await setupTest();
  const sum = await startStubGitleaksRelease('8.30.1', 'tampered gitleaks\n');

  const pinned = '551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb';

  expect(
    createAgentImageCheckDir(ctx.io, {
      work: ctx.work,
      repo: ctx.repo,
      pins: { GITLEAKS_VERSION: '8.30.1', GITLEAKS_SHA256: pinned },
    }),
  ).rejects.toMatchObject({
    exitCode: 1,
    message: `gitleaks_8.30.1_linux_x64.tar.gz has sha256 ${sum}, but images/agent/Dockerfile pins ${pinned}`,
  });

  expect(ctx.stub.calls).toStrictEqual([]);
});

test('it stops when the release download fails', async () => {
  const ctx = await setupTest();

  server.use(
    http.get(
      'https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz',
      () => new HttpResponse('Not Found', { status: 404 }),
    ),
  );

  expect(
    createAgentImageCheckDir(ctx.io, {
      work: ctx.work,
      repo: ctx.repo,
      pins: {
        GITLEAKS_VERSION: '8.30.1',
        GITLEAKS_SHA256: '551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb',
      },
    }),
  ).rejects.toMatchObject({
    exitCode: 1,
    message: 'cannot download gitleaks_8.30.1_linux_x64.tar.gz: HTTP 404',
  });
});

test('it stops when the Dockerfile pins no gitleaks', async () => {
  const ctx = await setupTest();

  expect(
    createAgentImageCheckDir(ctx.io, {
      work: ctx.work,
      repo: ctx.repo,
      pins: { BUN_VERSION: '1.4.2' },
    }),
  ).rejects.toMatchObject({
    exitCode: 1,
    message: 'images/agent/Dockerfile pins no GITLEAKS_VERSION and GITLEAKS_SHA256',
  });
});

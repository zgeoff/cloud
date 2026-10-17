import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildGitHubClient } from './build-github-client.ts';
import { buildImpdClient } from './build-impd-client.ts';
import { createPreviewStore } from './create-preview-store.ts';
import { makeLinkHandler } from './make-link-handler.ts';
import { makeSlotLock } from './make-slot-lock.ts';
import { githubAPIURL } from './mocks/github-api-url.ts';
import { composeFiles } from './mocks/github-state.ts';
import { NativeWebSocket } from './mocks/native-web-socket.ts';
import { startStubImpd } from './test-utils/start-stub-impd.ts';
import type { PreviewDeps } from './types.ts';

async function setupTest() {
  const dir = await mkdtemp(join(tmpdir(), 'preview-link-'));

  onTestFinished(() => rm(dir, { recursive: true, force: true }));

  const store = createPreviewStore(join(dir, 'previews.sqlite'));

  onTestFinished(() => {
    store.close();
  });

  const impd = startStubImpd();

  const pendingBoots = new Set<Promise<void>>();

  // a clock that each pause between health probes moves on
  const clock = { now: new Date('2026-10-15T09:00:00Z').getTime() };

  const deps: PreviewDeps = {
    settings: {
      baseURL: 'http://geoffcloud:8417',
      repos: new Set(['acme/greenhouse']),

      // one preview runs at a time
      slots: 1,
      idleMs: 1_800_000,

      // the domain each ready preview redirects under
      impDomain: 'imps.example.test',

      // the image and size each new imp boots with
      impImage: 'base',
      impMemoryMib: 2048,
      impGitHubSecret: 'gh',
      healthTimeoutMs: 60_000,
      healthPollMs: 1000,
      buildTimeoutMs: 1_800_000,
      contract: null,
    },
    store,
    impd: buildImpdClient(impd.url, impd.token, NativeWebSocket),
    github: buildGitHubClient(githubAPIURL, 'ghp_stub-preview-token'),
    webhookSecret: 'stub-webhook-secret',
    pendingBoots,
    pendingRuns: new Set(),
    withSlotLock: makeSlotLock(),
    now: () => new Date(clock.now),
    sleep: (ms) => {
      clock.now += ms;

      return Promise.resolve();
    },
    log: () => {},
  };

  return { handler: makeLinkHandler(deps), store, impd, pendingBoots };
}

test('it sleeps the running preview when a second one opens with one slot', async () => {
  const ctx = await setupTest();

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], {
    phase: 'ready',
    builtSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    lastActiveAt: '2026-10-15T08:55:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 18,
    imp: 'pv-0a1b2c3d-18',
    headSHA: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  });

  composeFiles.set('acme/greenhouse@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'services: {}\n');

  await ctx.handler(new Request('http://geoffcloud:8417/acme/greenhouse/18'));
  await Promise.all(ctx.pendingBoots);

  expect(ctx.impd.imps.get('pv-0a1b2c3d-17')?.state).toBe('sleeping');
  expect(ctx.impd.imps.get('pv-0a1b2c3d-18')?.state).toBe('running');
});

test('it runs one preview when two first opens with one slot arrive at once', async () => {
  const ctx = await setupTest();

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 18,
    imp: 'pv-0a1b2c3d-18',
    headSHA: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  });

  composeFiles.set('acme/greenhouse@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'services: {}\n');
  composeFiles.set('acme/greenhouse@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'services: {}\n');

  await Promise.all([
    ctx.handler(new Request('http://geoffcloud:8417/acme/greenhouse/17')),
    ctx.handler(new Request('http://geoffcloud:8417/acme/greenhouse/18')),
  ]);

  await Promise.all(ctx.pendingBoots);

  const running = [...ctx.impd.imps.values()].filter((imp) => imp.state === 'running');

  expect(running).toBeArrayOfSize(1);
});

test('it keeps both previews running when two slots fit them', async () => {
  const ctx = await setupTest();

  ctx.impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    lastActiveAt: '2026-10-15T08:55:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 18,
    imp: 'pv-0a1b2c3d-18',
    headSHA: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  });

  composeFiles.set('acme/greenhouse@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'services: {}\n');

  // the app listens on the imp's own address, so impd's proxy reaches it
  ctx.impd.apps.set('pv-0a1b2c3d-18', { address: '0.0.0.0', port: 8080 });

  const handler = makeLinkHandler({
    settings: {
      baseURL: 'http://geoffcloud:8417',
      repos: new Set(['acme/greenhouse']),
      slots: 2,
      idleMs: 1_800_000,
      impDomain: 'imps.example.test',
      impImage: 'base',
      impMemoryMib: 2048,
      impGitHubSecret: 'gh',
      healthTimeoutMs: 60_000,
      healthPollMs: 1000,
      buildTimeoutMs: 1_800_000,
      contract: null,
    },
    store: ctx.store,
    impd: buildImpdClient(ctx.impd.url, ctx.impd.token, NativeWebSocket),
    github: buildGitHubClient(githubAPIURL, 'ghp_stub-preview-token'),
    webhookSecret: 'stub-webhook-secret',
    pendingBoots: ctx.pendingBoots,
    pendingRuns: new Set(),
    withSlotLock: makeSlotLock(),
    now: () => new Date('2026-10-15T09:00:00Z'),
    sleep: async () => {},
    log: () => {},
  });

  await handler(new Request('http://geoffcloud:8417/acme/greenhouse/18'));

  await Promise.all(ctx.pendingBoots);

  expect(ctx.impd.imps.get('pv-0a1b2c3d-17')?.state).toBe('running');
});

test('it answers a first open with the booting page and boots the head commit', async () => {
  const ctx = await setupTest();

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 18,
    imp: 'pv-0a1b2c3d-18',
    headSHA: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  });

  composeFiles.set(
    'acme/greenhouse@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    'x-preview:\n  port: 3000\n  health: /healthz\nservices: {}\n',
  );

  ctx.impd.apps.set('pv-0a1b2c3d-18', { address: '0.0.0.0', port: 3000 });

  const response = await ctx.handler(new Request('http://geoffcloud:8417/acme/greenhouse/18'));

  await Promise.all(ctx.pendingBoots);

  const text = await response.text();

  expect(response.status).toBe(202);
  expect(text).toInclude('Booting acme/greenhouse#18 at bbbbbbb.');

  expect(ctx.store.findPreview({ repo: 'acme/greenhouse', number: 18 })).toStrictEqual({
    repo: 'acme/greenhouse',
    number: 18,
    imp: 'pv-0a1b2c3d-18',
    headSHA: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    builtSHA: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    phase: 'ready',
    detail: null,
  });
});

test('it answers a ready preview with a waiting page while another preview boots', async () => {
  const ctx = await setupTest();

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], {
    phase: 'ready',
    builtSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'sleeping',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  const otherBoot = Promise.withResolvers<void>();

  ctx.pendingBoots.add(otherBoot.promise);

  onTestFinished(() => {
    otherBoot.resolve();
  });

  const response = await ctx.handler(new Request('http://geoffcloud:8417/acme/greenhouse/17'));
  const text = await response.text();

  expect(response.status).toBe(202);
  expect(text).toInclude('Another preview is booting.');
  expect(ctx.impd.imps.get('pv-0a1b2c3d-17')?.state).toBe('sleeping');
});

test('it wakes a sleeping ready preview, checks its health and redirects to its imp', async () => {
  const ctx = await setupTest();

  composeFiles.set(
    'acme/greenhouse@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'x-preview:\n  health: /healthz\nservices: {}\n',
  );

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], {
    phase: 'ready',
    builtSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'sleeping',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  ctx.impd.apps.set('pv-0a1b2c3d-17', { address: '0.0.0.0', port: 8080 });

  const response = await ctx.handler(new Request('http://geoffcloud:8417/acme/greenhouse/17'));

  expect(response.status).toBe(302);
  expect(response.headers.get('location')).toBe('https://pv-0a1b2c3d-17.imps.example.test/');
  expect(ctx.impd.imps.get('pv-0a1b2c3d-17')?.state).toBe('running');
  expect(ctx.impd.proxied).toStrictEqual(['GET https://pv-0a1b2c3d-17.imps.example.test/healthz']);
  expect(ctx.impd.commands).toStrictEqual([]);
});

test('it boots a woken preview again when its stack never answers', async () => {
  const ctx = await setupTest();

  composeFiles.set(
    'acme/greenhouse@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'x-preview:\n  health: /healthz\nservices: {}\n',
  );

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], {
    phase: 'ready',
    builtSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'sleeping',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  // a cold boot left the stack down, so no app answers impd's proxy

  const response = await ctx.handler(new Request('http://geoffcloud:8417/acme/greenhouse/17'));

  await Promise.all(ctx.pendingBoots);

  expect(response.status).toBe(202);
  expect(ctx.impd.commands.map((command) => command.argv[0])).toContain('timeout');
});

test('it rebuilds a ready preview once a push moved its head', async () => {
  const ctx = await setupTest();

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], {
    phase: 'ready',
    builtSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'cccccccccccccccccccccccccccccccccccccccc',
  });

  ctx.impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  composeFiles.set('acme/greenhouse@cccccccccccccccccccccccccccccccccccccccc', 'services: {}\n');
  ctx.impd.apps.set('pv-0a1b2c3d-17', { address: '0.0.0.0', port: 8080 });

  const response = await ctx.handler(new Request('http://geoffcloud:8417/acme/greenhouse/17'));

  await Promise.all(ctx.pendingBoots);

  expect(response.status).toBe(202);

  expect(ctx.store.findPreview({ repo: 'acme/greenhouse', number: 17 })?.builtSHA).toBe(
    'cccccccccccccccccccccccccccccccccccccccc',
  );
});

test('it says the preview ended once its pull request closed', async () => {
  const ctx = await setupTest();

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], { phase: 'ended' });

  const response = await ctx.handler(new Request('http://geoffcloud:8417/acme/greenhouse/17'));
  const text = await response.text();

  expect(response.status).toBe(410);
  expect(text).toInclude('acme/greenhouse#17 closed, so its preview is gone.');
});

test('it shows a failed boot with a retry link and boots nothing', async () => {
  const ctx = await setupTest();

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], {
    phase: 'failed',
    detail: 'the build exited 1:\nseed: relation "plants" already exists',
  });

  const response = await ctx.handler(new Request('http://geoffcloud:8417/acme/greenhouse/17'));
  const text = await response.text();

  expect(response.status).toBe(502);
  expect(text).toInclude('<a href="/acme/greenhouse/17?retry=1">Retry the boot</a>');
  expect(ctx.impd.calls).toStrictEqual([]);
});

test('it boots a failed preview again when the retry link opens', async () => {
  const ctx = await setupTest();

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], {
    phase: 'failed',
    detail: 'the build exited 1',
  });

  composeFiles.set('acme/greenhouse@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'services: {}\n');
  ctx.impd.apps.set('pv-0a1b2c3d-17', { address: '0.0.0.0', port: 8080 });

  await ctx.handler(new Request('http://geoffcloud:8417/acme/greenhouse/17?retry=1'));
  await Promise.all(ctx.pendingBoots);

  expect(ctx.store.findPreview({ repo: 'acme/greenhouse', number: 17 })?.phase).toBe('ready');
});

test('it shows the failure page and boots nothing more when the booting page reloads after a failed retry', async () => {
  const ctx = await setupTest();

  composeFiles.set('acme/greenhouse@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'services: {}\n');

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], {
    phase: 'failed',
    detail: 'the build exited 1:\nseed: relation "plants" already exists',
  });

  // the retry's build fails the same way
  ctx.impd.answerCommand = (command) => ({ code: command.argv[0] === 'timeout' ? 1 : 0 });

  const retried = await ctx.handler(
    new Request('http://geoffcloud:8417/acme/greenhouse/17?retry=1'),
  );

  const retriedText = await retried.text();

  await Promise.all(ctx.pendingBoots);

  // a browser reloads the refresh's URL, or the page's own URL when the refresh names none
  const reloadPath =
    /content="5; url=(?<url>[^"]+)"/u.exec(retriedText)?.groups?.['url'] ??
    '/acme/greenhouse/17?retry=1';

  const commandsAfterRetry = ctx.impd.commands.length;

  const reloaded = await ctx.handler(new Request(`http://geoffcloud:8417${reloadPath}`));

  await Promise.all(ctx.pendingBoots);

  expect(reloaded.status).toBe(502);
  expect(ctx.pendingBoots.size).toBe(0);
  expect(ctx.impd.commands).toHaveLength(commandsAfterRetry);
});

test('it answers 404 for a pull request the service has not seen', async () => {
  const ctx = await setupTest();
  const response = await ctx.handler(new Request('http://geoffcloud:8417/acme/greenhouse/99'));
  const text = await response.text();

  expect(response.status).toBe(404);
  expect(text).toInclude('acme/greenhouse#99 has no preview');
});

test('it answers 404 for a path that names no pull request', async () => {
  const ctx = await setupTest();
  const response = await ctx.handler(new Request('http://geoffcloud:8417/acme'));

  expect(response.status).toBe(404);
});

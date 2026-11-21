import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { systemClock } from '@zgeoff/std';
import { createFakeClock } from '@zgeoff/testing/clock';
import { buildGitHubClient } from './build-github-client.ts';
import { buildImpdClient } from './build-impd-client.ts';
import { createPreviewStore } from './create-preview-store.ts';
import { makeLinkHandler } from './make-link-handler.ts';
import { makeSlotLock } from './make-slot-lock.ts';
import { composeFiles } from './src/test-utils/constants.ts';
import { githubAPIURL } from './src/test-utils/github-api-url.ts';
import { runUntilSettled } from './src/test-utils/run-until-settled.ts';
import { startPreviewImpd } from './src/test-utils/start-preview-impd.ts';
import { startStubImpd } from './src/test-utils/start-stub-impd.ts';
import { stubApp } from './src/test-utils/stub-app.ts';
import type { PreviewDeps } from './types.ts';

async function setupTest<Impd extends { readonly url: string; readonly token: string }>(
  impd: Impd,
) {
  const directory = await mkdtemp(join(tmpdir(), 'preview-link-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const store = createPreviewStore(join(directory, 'previews.sqlite'));

  onTestFinished(() => {
    store.close();
  });

  const pendingBoots = new Set<Promise<void>>();

  const clock = createFakeClock({ startMs: Date.parse('2026-10-15T09:00:00Z') });

  const deps: PreviewDeps = {
    settings: {
      baseURL: 'http://geoffcloud:8417',
      repos: new Set(['acme/greenhouse']),

      slots: 1,
      idleMs: 1_800_000,

      impDomain: 'imps.example.test',

      impImage: 'base',
      impMemoryMib: 2048,
      impMaxMemoryMib: 2048,
      impGitHubSecret: 'gh',
      impModelSecret: null,
      healthTimeoutMs: 60_000,
      healthPollMs: 1000,
      buildTimeoutMs: 1_800_000,
      contract: null,
    },
    spendProxies: null,
    store,
    impd: buildImpdClient(impd.url, impd.token),
    github: buildGitHubClient(githubAPIURL, stubApp, systemClock.now),
    webhookSecret: 'stub-webhook-secret',
    pendingBoots,
    pendingRuns: new Set(),
    withSlotLock: makeSlotLock(),
    now: clock.now,
    sleep: clock.sleep,
    log: () => {},
  };

  return { handler: makeLinkHandler(deps), store, impd, pendingBoots, clock };
}

test('it sleeps the running preview when a second one opens with one slot', async () => {
  const impd = startPreviewImpd();

  const ctx = await setupTest(impd);

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], { phase: 'booting' });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['booting'], {
    phase: 'ready',
    builtSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  await ctx.impd.seedImp({ name: 'pv-0a1b2c3d-17', grants: ['gh'] });

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 18,
    imp: 'pv-0a1b2c3d-18',
    headSHA: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  });

  composeFiles.set('acme/greenhouse@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'services: {}\n');

  await ctx.handler(new Request('http://geoffcloud:8417/acme/greenhouse/18'));

  await runUntilSettled(ctx.clock, Promise.all(ctx.pendingBoots), { maxMs: 3_600_000 });

  const slept = await ctx.impd.client.imps.get({ name: 'pv-0a1b2c3d-17' });
  const opened = await ctx.impd.client.imps.get({ name: 'pv-0a1b2c3d-18' });

  expect(slept.state).toBe('sleeping');
  expect(opened.state).toBe('running');
});

test('it runs one preview when two first opens with one slot arrive at once', async () => {
  const impd = startPreviewImpd();

  const ctx = await setupTest(impd);

  await ctx.impd.seedSecret('gh');

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

  await runUntilSettled(ctx.clock, Promise.all(ctx.pendingBoots), { maxMs: 3_600_000 });

  const imps = await ctx.impd.client.imps.list({});

  const running = imps.filter((imp) => imp.state === 'running');

  expect(running).toBeArrayOfSize(1);
});

test('it keeps both previews running when two slots fit them', async () => {
  const ctx = await setupTest(startStubImpd());

  ctx.impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    createdAt: '2026-09-01T00:00:00.000Z',
    lastActiveAt: '2026-10-15T08:55:00.000Z',
    lastRequestAt: '2026-10-15T08:55:00.000Z',
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
      impMaxMemoryMib: 2048,
      impGitHubSecret: 'gh',
      impModelSecret: null,
      healthTimeoutMs: 60_000,
      healthPollMs: 1000,
      buildTimeoutMs: 1_800_000,
      contract: null,
    },
    spendProxies: null,
    store: ctx.store,
    impd: buildImpdClient(ctx.impd.url, ctx.impd.token),
    github: buildGitHubClient(githubAPIURL, stubApp, systemClock.now),
    webhookSecret: 'stub-webhook-secret',
    pendingBoots: ctx.pendingBoots,
    pendingRuns: new Set(),
    withSlotLock: makeSlotLock(),
    now: ctx.clock.now,
    sleep: ctx.clock.sleep,
    log: () => {},
  });

  await handler(new Request('http://geoffcloud:8417/acme/greenhouse/18'));
  await runUntilSettled(ctx.clock, Promise.all(ctx.pendingBoots), { maxMs: 3_600_000 });

  expect(ctx.impd.imps.get('pv-0a1b2c3d-17')?.state).toBe('running');
});

test('it answers a first open with the booting page and boots the head commit', async () => {
  const ctx = await setupTest(startStubImpd());

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

  await runUntilSettled(ctx.clock, Promise.all(ctx.pendingBoots), { maxMs: 3_600_000 });

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
  const impd = startPreviewImpd();

  const ctx = await setupTest(impd);

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], { phase: 'booting' });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['booting'], {
    phase: 'ready',
    builtSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  await ctx.impd.seedImp({ name: 'pv-0a1b2c3d-17', state: 'sleeping', grants: ['gh'] });

  const otherBoot = Promise.withResolvers<void>();

  ctx.pendingBoots.add(otherBoot.promise);

  onTestFinished(() => {
    otherBoot.resolve();
  });

  const response = await ctx.handler(new Request('http://geoffcloud:8417/acme/greenhouse/17'));
  const text = await response.text();

  expect(response.status).toBe(202);
  expect(text).toInclude('Another preview is booting.');

  const heldImp = await ctx.impd.client.imps.get({ name: 'pv-0a1b2c3d-17' });

  expect(heldImp.state).toBe('sleeping');
});

test('it wakes a sleeping ready preview, checks its health and redirects to its imp', async () => {
  const ctx = await setupTest(startStubImpd());

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

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], { phase: 'booting' });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['booting'], {
    phase: 'ready',
    builtSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'sleeping',
    createdAt: '2026-09-01T00:00:00.000Z',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    lastRequestAt: '2026-10-15T08:00:00.000Z',
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

test.each(['running', 'sleeping'] as const)(
  'it puts a %s ready preview under the public egress policy before it redirects or wakes it',
  async (state) => {
    const ctx = await setupTest(startStubImpd());

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
      phase: 'booting',
    });

    ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['booting'], {
      phase: 'ready',
      builtSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    });

    ctx.impd.imps.set('pv-0a1b2c3d-17', {
      name: 'pv-0a1b2c3d-17',
      state,
      createdAt: '2026-09-01T00:00:00.000Z',
      lastActiveAt: '2026-10-15T08:00:00.000Z',
      lastRequestAt: '2026-10-15T08:00:00.000Z',
      httpPort: 8080,
      image: 'base',
      memoryMib: 2048,
      backup: false,
      grants: ['gh'],
    });

    ctx.impd.apps.set('pv-0a1b2c3d-17', { address: '0.0.0.0', port: 8080 });

    await ctx.handler(new Request('http://geoffcloud:8417/acme/greenhouse/17'));

    expect(ctx.impd.calls.slice(0, 2)).toStrictEqual([
      'imps/get pv-0a1b2c3d-17',
      'imps/setPolicy pv-0a1b2c3d-17',
    ]);

    expect(ctx.impd.egressModes).toStrictEqual(new Map([['pv-0a1b2c3d-17', 'public']]));
  },
);

test('it boots a woken preview again when its stack never answers', async () => {
  const ctx = await setupTest(startStubImpd());

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

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], { phase: 'booting' });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['booting'], {
    phase: 'ready',
    builtSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'sleeping',
    createdAt: '2026-09-01T00:00:00.000Z',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    lastRequestAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  // a cold boot left the stack down, so no app answers impd's proxy

  const response = await runUntilSettled(
    ctx.clock,
    ctx.handler(new Request('http://geoffcloud:8417/acme/greenhouse/17')),
    { maxMs: 3_600_000 },
  );

  await runUntilSettled(ctx.clock, Promise.all(ctx.pendingBoots), { maxMs: 3_600_000 });

  expect(response.status).toBe(202);
  expect(ctx.impd.commands.map((command) => command.argv[0])).toContain('timeout');
});

test('it rebuilds a ready preview once a push moved its head', async () => {
  const ctx = await setupTest(startStubImpd());

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], { phase: 'booting' });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['booting'], {
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
    createdAt: '2026-09-01T00:00:00.000Z',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    lastRequestAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  composeFiles.set('acme/greenhouse@cccccccccccccccccccccccccccccccccccccccc', 'services: {}\n');
  ctx.impd.apps.set('pv-0a1b2c3d-17', { address: '0.0.0.0', port: 8080 });

  const response = await ctx.handler(new Request('http://geoffcloud:8417/acme/greenhouse/17'));

  await runUntilSettled(ctx.clock, Promise.all(ctx.pendingBoots), { maxMs: 3_600_000 });

  expect(response.status).toBe(202);

  expect(ctx.store.findPreview({ repo: 'acme/greenhouse', number: 17 })?.builtSHA).toBe(
    'cccccccccccccccccccccccccccccccccccccccc',
  );
});

test('it says the preview ended once its pull request closed', async () => {
  const impd = startPreviewImpd();

  const ctx = await setupTest(impd);

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
  const impd = startPreviewImpd();

  const ctx = await setupTest(impd);

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], { phase: 'booting' });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['booting'], {
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
  const ctx = await setupTest(startStubImpd());

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], { phase: 'booting' });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['booting'], {
    phase: 'failed',
    detail: 'the build exited 1',
  });

  composeFiles.set('acme/greenhouse@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'services: {}\n');
  ctx.impd.apps.set('pv-0a1b2c3d-17', { address: '0.0.0.0', port: 8080 });

  await ctx.handler(new Request('http://geoffcloud:8417/acme/greenhouse/17?retry=1'));

  await runUntilSettled(ctx.clock, Promise.all(ctx.pendingBoots), { maxMs: 3_600_000 });

  expect(ctx.store.findPreview({ repo: 'acme/greenhouse', number: 17 })?.phase).toBe('ready');
});

test('it shows the failure page and boots nothing more when the booting page reloads after a failed retry', async () => {
  const ctx = await setupTest(startStubImpd());

  composeFiles.set('acme/greenhouse@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'services: {}\n');

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], { phase: 'booting' });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['booting'], {
    phase: 'failed',
    detail: 'the build exited 1:\nseed: relation "plants" already exists',
  });

  ctx.impd.answerCommand = (command) => ({ code: command.argv[0] === 'timeout' ? 1 : 0 });

  const retried = await ctx.handler(
    new Request('http://geoffcloud:8417/acme/greenhouse/17?retry=1'),
  );

  const retriedText = await retried.text();

  await runUntilSettled(ctx.clock, Promise.all(ctx.pendingBoots), { maxMs: 3_600_000 });

  // a browser reloads the refresh's URL, or the page's own URL when the refresh names none
  const reloadPath =
    /content="5; url=(?<url>[^"]+)"/u.exec(retriedText)?.groups?.['url'] ??
    '/acme/greenhouse/17?retry=1';

  const commandsAfterRetry = ctx.impd.commands.length;

  const reloaded = await ctx.handler(new Request(`http://geoffcloud:8417${reloadPath}`));

  await runUntilSettled(ctx.clock, Promise.all(ctx.pendingBoots), { maxMs: 3_600_000 });

  expect(reloaded.status).toBe(502);
  expect(ctx.pendingBoots.size).toBe(0);
  expect(ctx.impd.commands).toHaveLength(commandsAfterRetry);
});

test('it answers 404 for a pull request the service has not seen', async () => {
  const impd = startPreviewImpd();

  const ctx = await setupTest(impd);
  const response = await ctx.handler(new Request('http://geoffcloud:8417/acme/greenhouse/99'));
  const text = await response.text();

  expect(response.status).toBe(404);
  expect(text).toInclude('acme/greenhouse#99 has no preview');
});

test('it answers 404 for a path that names no pull request', async () => {
  const impd = startPreviewImpd();

  const ctx = await setupTest(impd);
  const response = await ctx.handler(new Request('http://geoffcloud:8417/acme'));

  expect(response.status).toBe(404);
});

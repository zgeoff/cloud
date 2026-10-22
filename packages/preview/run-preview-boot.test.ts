import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildGitHubClient } from './build-github-client.ts';
import { buildImpdClient } from './build-impd-client.ts';
import { createPreviewStore } from './create-preview-store.ts';
import { makeSlotLock } from './make-slot-lock.ts';
import { githubAPIURL } from './mocks/github-api-url.ts';
import { stubApp } from './mocks/github-app.ts';
import { composeFiles } from './mocks/github-state.ts';
import { NativeWebSocket } from './mocks/native-web-socket.ts';
import { runPreviewBoot } from './run-preview-boot.ts';
import { startStubImpd } from './test-utils/start-stub-impd.ts';
import type { PreviewDeps } from './types.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'preview-boot-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const store = createPreviewStore(join(directory, 'previews.sqlite'));

  onTestFinished(() => {
    store.close();
  });

  const impd = startStubImpd();
  const clock = { now: new Date('2026-10-15T09:00:00Z').getTime() };

  const deps: PreviewDeps = {
    settings: {
      baseURL: 'http://geoffcloud:8417',
      repos: new Set(['acme/greenhouse']),
      slots: 1,
      idleMs: 1_800_000,
      impDomain: 'imps.example.test',

      impImage: 'base',
      impMemoryMib: 2048,
      impGitHubSecret: 'gh',
      impModelSecret: null,

      // three probes fit before the boot times out
      healthTimeoutMs: 3000,
      healthPollMs: 1000,

      // half an hour bounds the build, the first argument of its timeout
      buildTimeoutMs: 1_800_000,
      contract: null,
    },
    spendProxies: null,
    store,
    impd: buildImpdClient(impd.url, impd.token, NativeWebSocket),
    github: buildGitHubClient(githubAPIURL, stubApp, () => new Date()),
    webhookSecret: 'stub-webhook-secret',
    pendingBoots: new Set(),
    pendingRuns: new Set(),
    withSlotLock: makeSlotLock(),
    now: () => new Date(clock.now),
    sleep: (durationMs) => {
      clock.now += durationMs;

      return Promise.resolve();
    },
    log: () => {},
  };

  return { deps, store, impd };
}

test('it creates the imp with the contract port and the grant, then builds and probes the head commit', async () => {
  const ctx = await setupTest();

  composeFiles.set(
    'acme/greenhouse@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'x-preview:\n  port: 3000\n  health: /healthz\nservices: {}\n',
  );

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], { phase: 'booting' });

  // the app listens on the imp's own address, so impd's proxy reaches it
  ctx.impd.apps.set('pv-0a1b2c3d-17', { address: '0.0.0.0', port: 3000 });

  await runPreviewBoot(ctx.deps, {
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    builtSHA: null,
    phase: 'booting',
    detail: null,
  });

  expect(ctx.impd.imps.get('pv-0a1b2c3d-17')).toStrictEqual({
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    lastActiveAt: expect.toSatisfy((value: string) => !Number.isNaN(Date.parse(value))),
    httpPort: 3000,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  expect(ctx.impd.commands).toStrictEqual([
    {
      imp: 'pv-0a1b2c3d-17',
      argv: [
        'timeout',
        '--kill-after=30',
        '1800',
        'sh',
        '-c',
        expect.toInclude('docker compose up --detach --build --wait'),
        'preview-boot',
        'acme/greenhouse',
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        '',
      ],
      require: ['broker'],
    },
  ]);

  expect(ctx.impd.proxied).toStrictEqual(['GET https://pv-0a1b2c3d-17.imps.example.test/healthz']);
  expect(ctx.store.findPreview({ repo: 'acme/greenhouse', number: 17 })?.phase).toBe('ready');
});

test("it starts the stack with compose.yaml and compose.broker.yaml, with the broker's CA bundle, when the commit has the broker file", async () => {
  const ctx = await setupTest();

  composeFiles.set('acme/greenhouse@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'services: {}\n');

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], { phase: 'booting' });

  await runPreviewBoot(ctx.deps, {
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    builtSHA: null,
    phase: 'booting',
    detail: null,
  });

  expect(ctx.impd.commands).toStrictEqual([
    {
      imp: 'pv-0a1b2c3d-17',
      argv: [
        'timeout',
        '--kill-after=30',
        '1800',
        'sh',
        '-c',
        expect.toInclude(
          [
            'cd preview',
            'if [ -f compose.broker.yaml ]; then',
            `  export BROKER_CA_FILE="\${SSL_CERT_FILE:?the broker's CA bundle did not reach the boot}"`,
            '  docker compose -f compose.yaml -f compose.broker.yaml up --detach --build --wait',
            'else',
            '  docker compose up --detach --build --wait',
            'fi',
          ].join('\n'),
        ),
        'preview-boot',
        'acme/greenhouse',
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        '',
      ],
      require: ['broker'],
    },
  ]);
});

test('it grants the model secret beside the GitHub secret, so the stack reaches the broker', async () => {
  const ctx = await setupTest();

  composeFiles.set('acme/greenhouse@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'services: {}\n');

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], { phase: 'booting' });

  await runPreviewBoot(
    { ...ctx.deps, settings: { ...ctx.deps.settings, impModelSecret: 'preview-model' } },
    {
      repo: 'acme/greenhouse',
      number: 17,
      imp: 'pv-0a1b2c3d-17',
      headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      builtSHA: null,
      phase: 'booting',
      detail: null,
    },
  );

  expect(ctx.impd.imps.get('pv-0a1b2c3d-17')?.grants).toStrictEqual(['gh', 'preview-model']);
});

test('it grants the model secret for the preview own route only, and passes the route to the stack, when the previews have counting proxies', async () => {
  const ctx = await setupTest();

  composeFiles.set('acme/greenhouse@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'services: {}\n');

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], { phase: 'booting' });

  await runPreviewBoot(
    {
      ...ctx.deps,
      settings: { ...ctx.deps.settings, impModelSecret: 'preview-model-counted' },
      spendProxies: {
        readOrigin: () => Promise.reject(new Error('a boot starts no counting proxy')),
        removeProxy: () => Promise.resolve(),
        removeIdle: () => Promise.resolve(),
        removeAll: () => Promise.resolve(),
      },
    },
    {
      repo: 'acme/greenhouse',
      number: 17,
      imp: 'pv-0a1b2c3d-17',
      headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      builtSHA: null,
      phase: 'booting',
      detail: null,
    },
  );

  expect(ctx.impd.imps.get('pv-0a1b2c3d-17')?.grants).toStrictEqual([
    'gh',
    'preview-model-counted',
  ]);

  expect(ctx.impd.grantPaths).toStrictEqual(
    new Map([['pv-0a1b2c3d-17 preview-model-counted', ['/pv-0a1b2c3d-17/**']]]),
  );

  expect(ctx.impd.commands).toMatchObject([
    {
      argv: [
        'timeout',
        '--kill-after=30',
        '1800',
        'sh',
        '-c',
        expect.toInclude('export PREVIEW_MODEL_ROUTE="$3"'),
        'preview-boot',
        'acme/greenhouse',
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'pv-0a1b2c3d-17',
      ],
    },
  ]);
});

test('it requires the broker for the build when the model secret is the only grant', async () => {
  const ctx = await setupTest();

  composeFiles.set('acme/greenhouse@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'services: {}\n');

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], { phase: 'booting' });

  await runPreviewBoot(
    {
      ...ctx.deps,
      settings: { ...ctx.deps.settings, impGitHubSecret: null, impModelSecret: 'preview-model' },
    },
    {
      repo: 'acme/greenhouse',
      number: 17,
      imp: 'pv-0a1b2c3d-17',
      headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      builtSHA: null,
      phase: 'booting',
      detail: null,
    },
  );

  expect(ctx.impd.imps.get('pv-0a1b2c3d-17')?.grants).toStrictEqual(['preview-model']);
  expect(ctx.impd.commands).toPartiallyContain({ imp: 'pv-0a1b2c3d-17', require: ['broker'] });
});

test('it records the tail of the build output when the build fails', async () => {
  const ctx = await setupTest();

  composeFiles.set('acme/greenhouse@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'services: {}\n');

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], { phase: 'booting' });

  ctx.impd.answerCommand = () => ({
    code: 1,
    stdout: 'service "seed" didn\'t complete successfully: exit 1\n',
  });

  await runPreviewBoot(ctx.deps, {
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    builtSHA: null,
    phase: 'booting',
    detail: null,
  });

  expect(ctx.store.findPreview({ repo: 'acme/greenhouse', number: 17 })).toMatchObject({
    phase: 'failed',
    detail: 'the build exited 1:\nservice "seed" didn\'t complete successfully: exit 1\n',
  });
});

test('it leaves a newer head waiting, not failed, when the older head it booted fails', async () => {
  const ctx = await setupTest();

  composeFiles.set('acme/greenhouse@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'services: {}\n');

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], { phase: 'booting' });

  // a push moves the head to the next commit while the older head's build runs, then that build
  // fails
  ctx.impd.answerCommand = () => {
    ctx.store.upsertHead({
      repo: 'acme/greenhouse',
      number: 17,
      imp: 'pv-0a1b2c3d-17',
      headSHA: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    });

    return { code: 1 };
  };

  await runPreviewBoot(ctx.deps, {
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    builtSHA: null,
    phase: 'booting',
    detail: null,
  });

  expect(ctx.store.findPreview({ repo: 'acme/greenhouse', number: 17 })).toStrictEqual({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    builtSHA: null,
    phase: 'waiting',
    detail: null,
  });
});

test("it fails the boot, naming the port, when the app listens on the guest's loopback alone", async () => {
  const ctx = await setupTest();

  composeFiles.set(
    'acme/greenhouse@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'x-preview:\n  port: 3000\n  health: /healthz\nservices: {}\n',
  );

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], { phase: 'booting' });

  // the build succeeds and the app answers inside the guest, but on 127.0.0.1 only
  ctx.impd.apps.set('pv-0a1b2c3d-17', { address: '127.0.0.1', port: 3000 });

  await runPreviewBoot(ctx.deps, {
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    builtSHA: null,
    phase: 'booting',
    detail: null,
  });

  expect(ctx.store.findPreview({ repo: 'acme/greenhouse', number: 17 })).toStrictEqual({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    builtSHA: null,
    phase: 'failed',
    detail: [
      "port 3000 did not answer https://pv-0a1b2c3d-17.imps.example.test/healthz through impd's proxy before the boot timed out.",
      "impd's proxy last answered: 502 Nothing answers in the imp: pv-0a1b2c3d-17 is awake, but nothing answered on port 3000 (Unable to connect. Is the computer able to access the url?).",
      'The app must listen on 0.0.0.0:3000 in the imp, not on 127.0.0.1 alone.',
    ].join('\n'),
  });

  expect(ctx.impd.proxied).toBeArrayOfSize(3);
});

test('it rebuilds an existing imp in place and takes the port of the new commit', async () => {
  const ctx = await setupTest();

  composeFiles.set(
    'acme/greenhouse@cccccccccccccccccccccccccccccccccccccccc',
    'x-preview:\n  port: 4000\nservices: {}\n',
  );

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'cccccccccccccccccccccccccccccccccccccccc',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], { phase: 'booting' });

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

  await runPreviewBoot(ctx.deps, {
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'cccccccccccccccccccccccccccccccccccccccc',
    builtSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    phase: 'booting',
    detail: null,
  });

  expect(ctx.impd.calls).toStrictEqual([
    'imps/get pv-0a1b2c3d-17',
    'imps/list',
    'imps/update pv-0a1b2c3d-17',
    'grants/list pv-0a1b2c3d-17',
    'exec/ticket pv-0a1b2c3d-17',
    'system/features',
    'system/info',
  ]);

  expect(ctx.impd.imps.get('pv-0a1b2c3d-17')?.httpPort).toBe(4000);
});

test('it adds the grant to an existing imp that lacks it, even after an earlier build', async () => {
  const ctx = await setupTest();

  composeFiles.set(
    'acme/greenhouse@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'x-preview:\n  port: 3000\nservices: {}\n',
  );

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], { phase: 'booting' });

  ctx.impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 3000,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: [],
  });

  await runPreviewBoot(ctx.deps, {
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    builtSHA: 'cccccccccccccccccccccccccccccccccccccccc',
    phase: 'booting',
    detail: null,
  });

  expect(ctx.impd.calls).toStrictEqual([
    'imps/get pv-0a1b2c3d-17',
    'imps/list',
    'imps/update pv-0a1b2c3d-17',
    'grants/list pv-0a1b2c3d-17',
    'grants/add pv-0a1b2c3d-17',
    'exec/ticket pv-0a1b2c3d-17',
    'system/features',
    'system/info',
  ]);

  expect(ctx.impd.imps.get('pv-0a1b2c3d-17')?.grants).toStrictEqual(['gh']);
});

test('it leaves a preview ended when its pull request closed during the boot', async () => {
  const ctx = await setupTest();

  composeFiles.set('acme/greenhouse@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'services: {}\n');

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], { phase: 'ended' });

  await runPreviewBoot(ctx.deps, {
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    builtSHA: null,
    phase: 'booting',
    detail: null,
  });

  expect(ctx.store.findPreview({ repo: 'acme/greenhouse', number: 17 })?.phase).toBe('ended');
});

test('it removes the imp it started when the pull request closed before the imp existed', async () => {
  const ctx = await setupTest();

  composeFiles.set('acme/greenhouse@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'services: {}\n');

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], { phase: 'ended' });

  await runPreviewBoot(ctx.deps, {
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    builtSHA: null,
    phase: 'booting',
    detail: null,
  });

  expect(ctx.impd.imps.has('pv-0a1b2c3d-17')).toBeFalse();
  expect(ctx.impd.commands).toStrictEqual([]);
});

test('it fails the boot when the head commit has no preview/compose.yaml', async () => {
  const ctx = await setupTest();

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], { phase: 'booting' });

  await runPreviewBoot(ctx.deps, {
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    builtSHA: null,
    phase: 'booting',
    detail: null,
  });

  expect(ctx.store.findPreview({ repo: 'acme/greenhouse', number: 17 })).toMatchObject({
    phase: 'failed',
    detail: 'preview/compose.yaml is gone at aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  expect(ctx.impd.calls).toStrictEqual([]);
});

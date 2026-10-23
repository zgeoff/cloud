import { expect, mock, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { HttpResponse, http } from 'msw';
import { z } from 'zod';
import { buildGitHubClient } from './build-github-client.ts';
import { buildImpdClient } from './build-impd-client.ts';
import { createPreviewStore } from './create-preview-store.ts';
import { makeSlotLock } from './make-slot-lock.ts';
import { githubAPIURL } from './mocks/github-api-url.ts';
import { stubApp } from './mocks/github-app.ts';
import { commitStatuses } from './mocks/github-state.ts';
import { NativeWebSocket } from './mocks/native-web-socket.ts';
import { server } from './mocks/node.ts';
import { runContractRun } from './run-contract-run.ts';
import { startStubImpd } from './test-utils/start-stub-impd.ts';
import type { PreviewDeps } from './types.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'preview-contract-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const store = createPreviewStore(join(directory, 'previews.sqlite'));

  onTestFinished(() => {
    store.close();
  });

  const impd = startStubImpd();

  const deps: PreviewDeps = {
    settings: {
      baseURL: 'http://geoffcloud:8417',
      repos: new Set(['acme/greenhouse']),

      // one slot, which a running preview or another run takes
      slots: 1,
      idleMs: 1_800_000,
      impDomain: impd.impDomain,
      impImage: 'pv-base',
      impMemoryMib: 4096,
      impGitHubSecret: 'gh',
      impModelSecret: null,
      healthTimeoutMs: 600_000,
      healthPollMs: 2000,
      buildTimeoutMs: 1_800_000,
      contract: {
        repos: new Set(['acme/greenhouse']),
        modelSecret: 'model-haiku',
        timeoutMs: 600_000,
        idleMs: 300_000,
      },
    },
    spendProxies: null,
    store,
    impd: buildImpdClient(impd.url, impd.token, NativeWebSocket),
    github: buildGitHubClient(githubAPIURL, stubApp, () => new Date()),
    webhookSecret: 'stub-webhook-secret',
    pendingBoots: new Set(),
    pendingRuns: new Set(),
    withSlotLock: makeSlotLock(),
    now: () => new Date('2026-10-15T09:00:00Z'),

    // the host's deadline never passes unless a test passes another sleep
    sleep: () => Promise.withResolvers<void>().promise,
    log: () => {},
  };

  return { deps, store, impd };
}

test('it runs the suite in a new imp with the model grant, posts success, and removes the imp', async () => {
  const ctx = await setupTest();

  ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    number: 17,
    imp: 'pv-sdk-0123456789abcdef',
  });

  const grants: string[] = [];

  ctx.impd.answerCommand = (command) => {
    grants.push(...(ctx.impd.imps.get(command.imp)?.grants ?? []));

    return { code: 0, stdout: ' 18 pass\n 0 fail\nRan 18 tests across 6 files.\n' };
  };

  await runContractRun(ctx.deps, {
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  expect(commitStatuses).toStrictEqual([
    {
      repo: 'acme/greenhouse',
      sha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      state: 'pending',
      context: 'sdk-contract',
      description: 'Running the SDK contract suite',
    },
    {
      repo: 'acme/greenhouse',
      sha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      state: 'success',
      context: 'sdk-contract',
      description: '18 pass, 0 fail',
    },
  ]);

  expect(grants).toStrictEqual(['model-haiku', 'gh']);
  expect(ctx.impd.imps.has('pv-sdk-0123456789abcdef')).toBeFalse();

  expect(
    ctx.store.findContractRun({
      repo: 'acme/greenhouse',
      headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    })?.phase,
  ).toBe('passed');
});

test("it runs the suite at the head commit under the guest's time limit, with the broker and the model placeholder", async () => {
  const ctx = await setupTest();

  ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    number: 17,
    imp: 'pv-sdk-0123456789abcdef',
  });

  await runContractRun(ctx.deps, {
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  expect(ctx.impd.commands).toStrictEqual([
    {
      imp: 'pv-sdk-0123456789abcdef',
      argv: [
        'timeout',
        '--kill-after=30',
        '600',
        'env',
        'ANTHROPIC_AUTH_TOKEN=imp-broker-placeholder',
        'sh',
        '-c',
        expect.toInclude('NIXIE_SDK_CONTRACT=1 bun test evals/sdk-contract'),
        'sdk-contract',
        'acme/greenhouse',
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ],
      require: ['broker'],
    },
  ]);
});

test('it posts failure with the counts when a probe fails, and removes the imp', async () => {
  const ctx = await setupTest();

  ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    number: 17,
    imp: 'pv-sdk-0123456789abcdef',
  });

  ctx.impd.answerCommand = () => ({ code: 1, stdout: ' 15 pass\n 3 fail\n' });

  await runContractRun(ctx.deps, {
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  expect(commitStatuses.at(-1)).toStrictEqual({
    repo: 'acme/greenhouse',
    sha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    state: 'failure',
    context: 'sdk-contract',
    description: '15 pass, 3 fail',
  });

  expect(ctx.impd.imps.has('pv-sdk-0123456789abcdef')).toBeFalse();
});

test('it posts failure and removes the imp when the run passes its time limit', async () => {
  const ctx = await setupTest();

  ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    number: 17,
    imp: 'pv-sdk-0123456789abcdef',
  });

  ctx.impd.answerCommand = () => ({ code: null, hold: true });

  const sleeps: number[] = [];

  await runContractRun(
    {
      ...ctx.deps,
      sleep: (durationMs) => {
        sleeps.push(durationMs);

        return Promise.resolve();
      },
    },
    { repo: 'acme/greenhouse', headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
  );

  expect(sleeps).toStrictEqual([690_000]);

  expect(commitStatuses.at(-1)).toStrictEqual({
    repo: 'acme/greenhouse',
    sha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    state: 'failure',
    context: 'sdk-contract',
    description: 'The suite ran past its 10 min limit',
  });

  expect(ctx.impd.imps.has('pv-sdk-0123456789abcdef')).toBeFalse();

  expect(
    ctx.store.findContractRun({
      repo: 'acme/greenhouse',
      headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    })?.phase,
  ).toBe('failed');
});

test('it posts pending with the reason, starts no imp, and leaves the preview awake when a preview used within the idle time holds every slot', async () => {
  const ctx = await setupTest();

  ctx.impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    lastActiveAt: '2026-10-15T08:59:00.000Z',
    httpPort: 8080,
    image: 'pv-base',
    memoryMib: 4096,
    backup: false,
    grants: ['gh'],
  });

  ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    number: 18,
    imp: 'pv-sdk-0123456789abcdef',
  });

  await runContractRun(ctx.deps, {
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  expect(commitStatuses).toStrictEqual([
    {
      repo: 'acme/greenhouse',
      sha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      state: 'pending',
      context: 'sdk-contract',
      description: 'Waiting for a free preview slot',
    },
  ]);

  expect([...ctx.impd.imps.keys()]).toStrictEqual(['pv-0a1b2c3d-17']);
  expect(ctx.impd.imps.get('pv-0a1b2c3d-17')?.state).toBe('running');

  expect(
    ctx.store.findContractRun({
      repo: 'acme/greenhouse',
      headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    })?.phase,
  ).toBe('waiting');
});

test('it posts nothing new when a retry still finds every slot taken', async () => {
  const ctx = await setupTest();

  ctx.impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    lastActiveAt: '2026-10-15T08:59:00.000Z',
    httpPort: 8080,
    image: 'pv-base',
    memoryMib: 4096,
    backup: false,
    grants: ['gh'],
  });

  ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    number: 18,
    imp: 'pv-sdk-0123456789abcdef',
  });

  ctx.store.updateContractPhase(
    { repo: 'acme/greenhouse', headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
    ['queued'],
    { phase: 'waiting', detail: 'Waiting for a free preview slot' },
  );

  await runContractRun(ctx.deps, {
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  expect(commitStatuses).toStrictEqual([]);
});

test('it puts a preview unused for the idle time to sleep and runs a waiting run in its slot', async () => {
  const ctx = await setupTest();

  ctx.impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    lastActiveAt: '2026-10-15T08:55:00.000Z',
    httpPort: 8080,
    image: 'pv-base',
    memoryMib: 4096,
    backup: false,
    grants: ['gh'],
  });

  ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    number: 18,
    imp: 'pv-sdk-0123456789abcdef',
  });

  ctx.store.updateContractPhase(
    { repo: 'acme/greenhouse', headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
    ['queued'],
    { phase: 'waiting', detail: 'Waiting for a free preview slot' },
  );

  ctx.impd.answerCommand = () => ({ code: 0, stdout: ' 18 pass\n 0 fail\n' });

  const log = mock<(line: string) => void>();

  await runContractRun(
    { ...ctx.deps, log },
    { repo: 'acme/greenhouse', headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
  );

  expect(ctx.impd.imps.get('pv-0a1b2c3d-17')?.state).toBe('sleeping');

  expect(commitStatuses.map((status) => status.description)).toStrictEqual([
    'Running the SDK contract suite',
    '18 pass, 0 fail',
  ]);

  expect(log.mock.calls[0]).toStrictEqual([
    'pv-0a1b2c3d-17: asleep to free a slot for the SDK contract run of acme/greenhouse@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  ]);
});

test('it keeps the run waiting and starts no imp when impd refuses to sleep the idle preview', async () => {
  const ctx = await setupTest();

  ctx.impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'pv-base',
    memoryMib: 4096,
    backup: false,
    grants: ['gh'],
  });

  ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    number: 18,
    imp: 'pv-sdk-0123456789abcdef',
  });

  server.use(
    http.post(`${ctx.impd.url}/rpc/imps/sleep`, () =>
      HttpResponse.json(
        {
          json: {
            defined: true,
            code: 'CONFLICT',
            status: 409,
            message: 'pv-0a1b2c3d-17 holds a lease',
          },
        },
        { status: 409 },
      ),
    ),
  );

  const log = mock<(line: string) => void>();

  await runContractRun(
    { ...ctx.deps, log },
    { repo: 'acme/greenhouse', headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
  );

  expect([...ctx.impd.imps.keys()]).toStrictEqual(['pv-0a1b2c3d-17']);
  expect(ctx.impd.imps.get('pv-0a1b2c3d-17')?.state).toBe('running');

  expect(commitStatuses.map((status) => status.description)).toStrictEqual([
    'Waiting for a free preview slot',
  ]);

  expect(log.mock.calls).toStrictEqual([
    [
      'pv-0a1b2c3d-17: could not sleep it to free a slot for a contract run: ImpdError: impd CONFLICT: pv-0a1b2c3d-17 holds a lease',
    ],
  ]);

  expect(
    ctx.store.findContractRun({
      repo: 'acme/greenhouse',
      headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    })?.phase,
  ).toBe('waiting');
});

test('it runs a waiting run once a slot is free', async () => {
  const ctx = await setupTest();

  ctx.impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'sleeping',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'pv-base',
    memoryMib: 4096,
    backup: false,
    grants: ['gh'],
  });

  ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    number: 18,
    imp: 'pv-sdk-0123456789abcdef',
  });

  ctx.store.updateContractPhase(
    { repo: 'acme/greenhouse', headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
    ['queued'],
    { phase: 'waiting', detail: 'Waiting for a free preview slot' },
  );

  ctx.impd.answerCommand = () => ({ code: 0, stdout: ' 18 pass\n 0 fail\n' });

  await runContractRun(ctx.deps, {
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  expect(commitStatuses.map((status) => status.state)).toStrictEqual(['pending', 'success']);
});

test('it starts nothing for a run that already ended', async () => {
  const ctx = await setupTest();

  ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    number: 17,
    imp: 'pv-sdk-0123456789abcdef',
  });

  ctx.store.updateContractPhase(
    { repo: 'acme/greenhouse', headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
    ['queued'],
    { phase: 'settling', detail: '18 pass, 0 fail', outcome: 'success' },
  );

  ctx.store.updateContractPhase(
    { repo: 'acme/greenhouse', headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
    ['settling'],
    { phase: 'passed', detail: '18 pass, 0 fail', outcome: 'success' },
  );

  await runContractRun(ctx.deps, {
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  expect(ctx.impd.calls).toStrictEqual([]);
  expect(commitStatuses).toStrictEqual([]);
});

test('it removes an imp that a stopped service left behind and runs on a new one', async () => {
  const ctx = await setupTest();

  ctx.impd.imps.set('pv-sdk-0123456789abcdef', {
    name: 'pv-sdk-0123456789abcdef',
    state: 'running',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'pv-base',
    memoryMib: 4096,
    backup: false,
    grants: ['model-haiku', 'gh'],
  });

  ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    number: 17,
    imp: 'pv-sdk-0123456789abcdef',
  });

  await runContractRun(ctx.deps, {
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  expect(ctx.impd.calls.slice(0, 3)).toStrictEqual([
    'imps/list',
    'imps/destroy pv-sdk-0123456789abcdef',
    'imps/create pv-sdk-0123456789abcdef',
  ]);
});

test('it posts an error status when impd refuses to start the imp', async () => {
  const ctx = await setupTest();

  ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    number: 17,
    imp: 'pv-sdk-0123456789abcdef',
  });

  // impd's oRPC error body for a create that its memory budget refuses
  server.use(
    http.post(`${ctx.impd.url}/rpc/imps/create`, () =>
      HttpResponse.json(
        {
          json: {
            defined: true,
            code: 'INSUFFICIENT_MEMORY',
            status: 507,
            message: 'the memory budget is spent',
          },
        },
        { status: 507 },
      ),
    ),
  );

  await runContractRun(ctx.deps, {
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  expect(commitStatuses).toStrictEqual([
    {
      repo: 'acme/greenhouse',
      sha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      state: 'error',
      context: 'sdk-contract',
      description:
        "The run's imp did not start: impd INSUFFICIENT_MEMORY: the memory budget is spent",
    },
  ]);

  expect(
    ctx.store.findContractRun({
      repo: 'acme/greenhouse',
      headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    })?.phase,
  ).toBe('failed');
});

test('it ends a queued run with an error and removes its imp once the contract settings are gone', async () => {
  const ctx = await setupTest();

  ctx.impd.imps.set('pv-sdk-0123456789abcdef', {
    name: 'pv-sdk-0123456789abcdef',
    state: 'running',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'pv-base',
    memoryMib: 4096,
    backup: false,
    grants: ['model-haiku', 'gh'],
  });

  ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    number: 17,
    imp: 'pv-sdk-0123456789abcdef',
  });

  await runContractRun(
    { ...ctx.deps, settings: { ...ctx.deps.settings, contract: null } },
    { repo: 'acme/greenhouse', headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
  );

  expect(ctx.impd.imps.has('pv-sdk-0123456789abcdef')).toBeFalse();
  expect(ctx.impd.commands).toStrictEqual([]);

  expect(commitStatuses).toStrictEqual([
    {
      repo: 'acme/greenhouse',
      sha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      state: 'error',
      context: 'sdk-contract',
      description: 'The SDK contract run is off on this service',
    },
  ]);

  expect(
    ctx.store.findContractRun({
      repo: 'acme/greenhouse',
      headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    })?.phase,
  ).toBe('failed');
});

test('it keeps the result settling when GitHub answers the final status with a server error', async () => {
  const ctx = await setupTest();

  ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    number: 17,
    imp: 'pv-sdk-0123456789abcdef',
  });

  ctx.impd.answerCommand = () => ({ code: 0, stdout: ' 18 pass\n 0 fail\n' });

  // GitHub's answer to a status while it is down, for every status but the pending ones
  server.use(
    http.post(`${githubAPIURL}/repos/acme/greenhouse/statuses/:sha`, async (info) => {
      const body = await info.request.clone().json();

      const payload = z.object({ state: z.string() }).parse(body);

      return payload.state === 'pending'
        ? undefined
        : HttpResponse.json({ message: 'Server Error' }, { status: 502 });
    }),
  );

  await runContractRun(ctx.deps, {
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  expect(
    ctx.store.findContractRun({
      repo: 'acme/greenhouse',
      headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    }),
  ).toMatchObject({ phase: 'settling', detail: '18 pass, 0 fail', outcome: 'success' });

  expect(commitStatuses.map((status) => status.state)).toStrictEqual(['pending']);
});

test('it ends a settling run with the refusal and posts no status again when GitHub refuses the final status for good', async () => {
  const ctx = await setupTest();

  ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    number: 17,
    imp: 'pv-sdk-0123456789abcdef',
  });

  ctx.store.updateContractPhase(
    { repo: 'acme/greenhouse', headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
    ['queued'],
    { phase: 'settling', detail: '18 pass, 0 fail', outcome: 'success' },
  );

  const recordStatusPost = mock((sha: string) => sha);
  const recordLog = mock((line: string) => line);

  // GitHub's answer to an App without Commit statuses write (docs.github.com/en/rest:
  // authentication/permissions-required-for-github-apps)
  server.use(
    http.post(`${githubAPIURL}/repos/acme/greenhouse/statuses/:sha`, (info) => {
      recordStatusPost(String(info.params['sha']));

      return HttpResponse.json(
        { message: 'Resource not accessible by integration', status: '403' },
        { status: 403, headers: { 'x-accepted-github-permissions': 'statuses=write' } },
      );
    }),
  );

  const deps = { ...ctx.deps, log: recordLog };
  const key = { repo: 'acme/greenhouse', headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' };

  await runContractRun(deps, key);
  await runContractRun(deps, key);

  expect(ctx.store.findContractRun(key)).toStrictEqual({
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    number: 17,
    imp: 'pv-sdk-0123456789abcdef',
    phase: 'passed',
    detail:
      '18 pass, 0 fail; the status was not posted: GitHub POST /repos/acme/greenhouse/statuses/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: HTTP 403: Resource not accessible by integration (the App needs statuses=write)',
    outcome: 'success',
  });

  expect(recordStatusPost.mock.calls).toStrictEqual([['aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa']]);

  expect(recordLog.mock.calls).toStrictEqual([
    [
      'acme/greenhouse@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: the SDK contract run ended: 18 pass, 0 fail; the status was not posted: GitHub POST /repos/acme/greenhouse/statuses/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: HTTP 403: Resource not accessible by integration (the App needs statuses=write)',
    ],
  ]);
});

test('it keeps the result settling and the status unset when impd fails to remove the imp', async () => {
  const ctx = await setupTest();

  ctx.impd.imps.set('pv-sdk-0123456789abcdef', {
    name: 'pv-sdk-0123456789abcdef',
    state: 'running',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'pv-base',
    memoryMib: 4096,
    backup: false,
    grants: ['model-haiku', 'gh'],
  });

  ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    number: 17,
    imp: 'pv-sdk-0123456789abcdef',
  });

  ctx.store.updateContractPhase(
    { repo: 'acme/greenhouse', headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
    ['queued'],
    { phase: 'settling', detail: '15 pass, 3 fail', outcome: 'failure' },
  );

  await runContractRun(
    { ...ctx.deps, impd: buildImpdClient(ctx.impd.url, 'imp_wrong.token', NativeWebSocket) },
    { repo: 'acme/greenhouse', headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
  );

  expect(ctx.impd.imps.has('pv-sdk-0123456789abcdef')).toBeTrue();
  expect(commitStatuses).toStrictEqual([]);

  expect(
    ctx.store.findContractRun({
      repo: 'acme/greenhouse',
      headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    })?.phase,
  ).toBe('settling');
});

test('it settles a settling run on its next try: removes the imp, posts the stored result, and ends it', async () => {
  const ctx = await setupTest();

  ctx.impd.imps.set('pv-sdk-0123456789abcdef', {
    name: 'pv-sdk-0123456789abcdef',
    state: 'running',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'pv-base',
    memoryMib: 4096,
    backup: false,
    grants: ['model-haiku', 'gh'],
  });

  ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    number: 17,
    imp: 'pv-sdk-0123456789abcdef',
  });

  ctx.store.updateContractPhase(
    { repo: 'acme/greenhouse', headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
    ['queued'],
    { phase: 'settling', detail: '15 pass, 3 fail', outcome: 'failure' },
  );

  await runContractRun(ctx.deps, {
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  expect(ctx.impd.imps.has('pv-sdk-0123456789abcdef')).toBeFalse();
  expect(ctx.impd.commands).toStrictEqual([]);

  expect(commitStatuses).toStrictEqual([
    {
      repo: 'acme/greenhouse',
      sha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      state: 'failure',
      context: 'sdk-contract',
      description: '15 pass, 3 fail',
    },
  ]);

  expect(
    ctx.store.findContractRun({
      repo: 'acme/greenhouse',
      headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    })?.phase,
  ).toBe('failed');
});

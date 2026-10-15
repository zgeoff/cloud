/* oxlint-disable import/max-dependencies, max-lines-per-function */
import { expect, onTestFinished, test } from 'bun:test';
import { createHmac } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildGitHubClient } from './build-github-client.ts';
import { buildImpdClient } from './build-impd-client.ts';
import { createPreviewStore } from './create-preview-store.ts';
import { makeSlotLock } from './make-slot-lock.ts';
import { makeWebhookHandler } from './make-webhook-handler.ts';
import { githubAPIURL } from './mocks/github-api-url.ts';
import { composeFiles, issueComments } from './mocks/github-state.ts';
import { NativeWebSocket } from './mocks/native-web-socket.ts';
import { startStubImpd } from './test-utils/start-stub-impd.ts';
import type { PreviewDeps } from './types.ts';

async function setupTest() {
  const dir = await mkdtemp(join(tmpdir(), 'preview-webhook-'));

  onTestFinished(() => rm(dir, { recursive: true, force: true }));

  const store = createPreviewStore(join(dir, 'previews.sqlite'));

  onTestFinished(() => {
    store.close();
  });

  const impd = startStubImpd();

  const deps: PreviewDeps = {
    settings: {
      // the link's origin, which every comment carries
      baseURL: 'http://geoffcloud:8417',

      // one repository listed by name, and every repository of one owner
      repos: new Set(['acme/greenhouse', 'nursery/*']),

      // the handler never reads the rest, which the link and the boot use
      slots: 1,
      idleMs: 1_800_000,
      impDomain: 'imps.example.test',
      impImage: 'base',
      impMemoryMib: 2048,
      impGitHubSecret: 'gh',
      healthTimeoutMs: 60_000,
      healthPollMs: 1000,
    },
    store,
    impd: buildImpdClient(impd.url, impd.token, NativeWebSocket),
    github: buildGitHubClient(githubAPIURL, 'ghp_stub-preview-token'),

    // the secret every delivery below is signed with, or deliberately not
    webhookSecret: 'stub-webhook-secret',
    pendingBoots: new Set(),
    withSlotLock: makeSlotLock(),
    now: () => new Date('2026-10-15T09:00:00Z'),
    sleep: async () => {},
    log: () => {},
  };

  return { handler: makeWebhookHandler(deps), store, impd };
}

test('it posts one comment with the tailnet link when a pull request opens', async () => {
  const ctx = await setupTest();

  composeFiles.set(
    'acme/greenhouse@4d2a7c1e9b0f3a5d6c8e7f1a2b3c4d5e6f7a8b9c',
    'services:\n  web:\n    image: nginx\n',
  );

  const body = JSON.stringify({
    action: 'opened',
    number: 17,
    repository: { full_name: 'acme/greenhouse' },
    pull_request: {
      head: {
        sha: '4d2a7c1e9b0f3a5d6c8e7f1a2b3c4d5e6f7a8b9c',
        repo: { full_name: 'acme/greenhouse' },
      },
    },
  });

  const response = await ctx.handler(
    new Request('http://preview.test/webhook', {
      method: 'POST',
      headers: {
        'x-github-event': 'pull_request',
        'x-hub-signature-256': `sha256=${createHmac('sha256', 'stub-webhook-secret').update(body).digest('hex')}`,
      },
      body,
    }),
  );

  expect(response.status).toBe(204);

  expect(issueComments).toStrictEqual([
    {
      id: expect.toBeNumber(),
      repo: 'acme/greenhouse',
      number: 17,
      body: expect.toInclude('**Preview:** http://geoffcloud:8417/acme/greenhouse/17'),
    },
  ]);
});

test('it edits the same comment when a push moves the head of the pull request', async () => {
  const ctx = await setupTest();

  composeFiles.set('acme/greenhouse@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'services: {}\n');
  composeFiles.set('acme/greenhouse@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'services: {}\n');

  const opened = JSON.stringify({
    action: 'opened',
    number: 17,
    repository: { full_name: 'acme/greenhouse' },
    pull_request: {
      head: {
        sha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        repo: { full_name: 'acme/greenhouse' },
      },
    },
  });

  await ctx.handler(
    new Request('http://preview.test/webhook', {
      method: 'POST',
      headers: {
        'x-github-event': 'pull_request',
        'x-hub-signature-256': `sha256=${createHmac('sha256', 'stub-webhook-secret').update(opened).digest('hex')}`,
      },
      body: opened,
    }),
  );

  const pushed = JSON.stringify({
    action: 'synchronize',
    number: 17,
    repository: { full_name: 'acme/greenhouse' },
    pull_request: {
      head: {
        sha: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        repo: { full_name: 'acme/greenhouse' },
      },
    },
  });

  await ctx.handler(
    new Request('http://preview.test/webhook', {
      method: 'POST',
      headers: {
        'x-github-event': 'pull_request',
        'x-hub-signature-256': `sha256=${createHmac('sha256', 'stub-webhook-secret').update(pushed).digest('hex')}`,
      },
      body: pushed,
    }),
  );

  expect(issueComments).toStrictEqual([
    {
      id: expect.toBeNumber(),
      repo: 'acme/greenhouse',
      number: 17,
      body: expect.toInclude('Opening the link boots `bbbbbbb`'),
    },
  ]);
});

test('it refuses an unsigned delivery', async () => {
  const ctx = await setupTest();

  composeFiles.set('acme/greenhouse@4d2a7c1e9b0f3a5d6c8e7f1a2b3c4d5e6f7a8b9c', 'services: {}\n');

  const response = await ctx.handler(
    new Request('http://preview.test/webhook', {
      method: 'POST',
      headers: { 'x-github-event': 'pull_request' },
      body: JSON.stringify({
        action: 'opened',
        number: 17,
        repository: { full_name: 'acme/greenhouse' },
        pull_request: {
          head: {
            sha: '4d2a7c1e9b0f3a5d6c8e7f1a2b3c4d5e6f7a8b9c',
            repo: { full_name: 'acme/greenhouse' },
          },
        },
      }),
    }),
  );

  expect(response.status).toBe(401);
  expect(issueComments).toStrictEqual([]);
  expect(ctx.store.findPreview({ repo: 'acme/greenhouse', number: 17 })).toBeNull();
});

test('it refuses a delivery signed with another secret', async () => {
  const ctx = await setupTest();

  composeFiles.set('acme/greenhouse@4d2a7c1e9b0f3a5d6c8e7f1a2b3c4d5e6f7a8b9c', 'services: {}\n');

  const body = JSON.stringify({
    action: 'opened',
    number: 17,
    repository: { full_name: 'acme/greenhouse' },
    pull_request: {
      head: {
        sha: '4d2a7c1e9b0f3a5d6c8e7f1a2b3c4d5e6f7a8b9c',
        repo: { full_name: 'acme/greenhouse' },
      },
    },
  });

  const response = await ctx.handler(
    new Request('http://preview.test/webhook', {
      method: 'POST',
      headers: {
        'x-github-event': 'pull_request',
        'x-hub-signature-256': `sha256=${createHmac('sha256', 'a-guessed-secret').update(body).digest('hex')}`,
      },
      body,
    }),
  );

  expect(response.status).toBe(401);
  expect(issueComments).toStrictEqual([]);
  expect(ctx.store.findPreview({ repo: 'acme/greenhouse', number: 17 })).toBeNull();
});

test('it refuses a delivery whose body changed after it was signed', async () => {
  const ctx = await setupTest();

  composeFiles.set('acme/greenhouse@4d2a7c1e9b0f3a5d6c8e7f1a2b3c4d5e6f7a8b9c', 'services: {}\n');

  const signedBody = JSON.stringify({ action: 'labeled', number: 17 });

  const response = await ctx.handler(
    new Request('http://preview.test/webhook', {
      method: 'POST',
      headers: {
        'x-github-event': 'pull_request',
        'x-hub-signature-256': `sha256=${createHmac('sha256', 'stub-webhook-secret').update(signedBody).digest('hex')}`,
      },
      body: JSON.stringify({
        action: 'opened',
        number: 17,
        repository: { full_name: 'acme/greenhouse' },
        pull_request: {
          head: {
            sha: '4d2a7c1e9b0f3a5d6c8e7f1a2b3c4d5e6f7a8b9c',
            repo: { full_name: 'acme/greenhouse' },
          },
        },
      }),
    }),
  );

  expect(response.status).toBe(401);
  expect(issueComments).toStrictEqual([]);
});

test('it posts nothing for a repository the service does not list', async () => {
  const ctx = await setupTest();

  composeFiles.set('acme/orchard@4d2a7c1e9b0f3a5d6c8e7f1a2b3c4d5e6f7a8b9c', 'services: {}\n');

  const body = JSON.stringify({
    action: 'opened',
    number: 17,
    repository: { full_name: 'acme/orchard' },
    pull_request: {
      head: {
        sha: '4d2a7c1e9b0f3a5d6c8e7f1a2b3c4d5e6f7a8b9c',
        repo: { full_name: 'acme/orchard' },
      },
    },
  });

  const response = await ctx.handler(
    new Request('http://preview.test/webhook', {
      method: 'POST',
      headers: {
        'x-github-event': 'pull_request',
        'x-hub-signature-256': `sha256=${createHmac('sha256', 'stub-webhook-secret').update(body).digest('hex')}`,
      },
      body,
    }),
  );

  expect(response.status).toBe(204);
  expect(issueComments).toStrictEqual([]);
});

test('it posts the link for a repository its owner wildcard lists', async () => {
  const ctx = await setupTest();

  composeFiles.set('nursery/seedlings@4d2a7c1e9b0f3a5d6c8e7f1a2b3c4d5e6f7a8b9c', 'services: {}\n');

  const body = JSON.stringify({
    action: 'opened',
    number: 3,
    repository: { full_name: 'nursery/seedlings' },
    pull_request: {
      head: {
        sha: '4d2a7c1e9b0f3a5d6c8e7f1a2b3c4d5e6f7a8b9c',
        repo: { full_name: 'nursery/seedlings' },
      },
    },
  });

  await ctx.handler(
    new Request('http://preview.test/webhook', {
      method: 'POST',
      headers: {
        'x-github-event': 'pull_request',
        'x-hub-signature-256': `sha256=${createHmac('sha256', 'stub-webhook-secret').update(body).digest('hex')}`,
      },
      body,
    }),
  );

  expect(issueComments).toStrictEqual([
    {
      id: expect.toBeNumber(),
      repo: 'nursery/seedlings',
      number: 3,
      body: expect.toInclude('**Preview:** http://geoffcloud:8417/nursery/seedlings/3'),
    },
  ]);
});

test('it posts nothing for a pull request from a fork', async () => {
  const ctx = await setupTest();

  composeFiles.set('acme/greenhouse@4d2a7c1e9b0f3a5d6c8e7f1a2b3c4d5e6f7a8b9c', 'services: {}\n');

  const body = JSON.stringify({
    action: 'opened',
    number: 17,
    repository: { full_name: 'acme/greenhouse' },
    pull_request: {
      head: {
        sha: '4d2a7c1e9b0f3a5d6c8e7f1a2b3c4d5e6f7a8b9c',
        repo: { full_name: 'stranger/greenhouse' },
      },
    },
  });

  await ctx.handler(
    new Request('http://preview.test/webhook', {
      method: 'POST',
      headers: {
        'x-github-event': 'pull_request',
        'x-hub-signature-256': `sha256=${createHmac('sha256', 'stub-webhook-secret').update(body).digest('hex')}`,
      },
      body,
    }),
  );

  expect(issueComments).toStrictEqual([]);
});

test('it posts nothing for a head commit without preview/compose.yaml', async () => {
  const ctx = await setupTest();

  const body = JSON.stringify({
    action: 'opened',
    number: 17,
    repository: { full_name: 'acme/greenhouse' },
    pull_request: {
      head: {
        sha: '4d2a7c1e9b0f3a5d6c8e7f1a2b3c4d5e6f7a8b9c',
        repo: { full_name: 'acme/greenhouse' },
      },
    },
  });

  await ctx.handler(
    new Request('http://preview.test/webhook', {
      method: 'POST',
      headers: {
        'x-github-event': 'pull_request',
        'x-hub-signature-256': `sha256=${createHmac('sha256', 'stub-webhook-secret').update(body).digest('hex')}`,
      },
      body,
    }),
  );

  expect(issueComments).toStrictEqual([]);
});

test('it removes the imp and says the preview ended when the pull request closes', async () => {
  const ctx = await setupTest();

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0bcd7c17-17',
    headSHA: '4d2a7c1e9b0f3a5d6c8e7f1a2b3c4d5e6f7a8b9c',
  });

  ctx.impd.imps.set('pv-0bcd7c17-17', {
    name: 'pv-0bcd7c17-17',
    state: 'running',
    lastActiveAt: null,
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  const body = JSON.stringify({
    action: 'closed',
    number: 17,
    repository: { full_name: 'acme/greenhouse' },
    pull_request: {
      head: {
        sha: '4d2a7c1e9b0f3a5d6c8e7f1a2b3c4d5e6f7a8b9c',
        repo: { full_name: 'acme/greenhouse' },
      },
    },
  });

  await ctx.handler(
    new Request('http://preview.test/webhook', {
      method: 'POST',
      headers: {
        'x-github-event': 'pull_request',
        'x-hub-signature-256': `sha256=${createHmac('sha256', 'stub-webhook-secret').update(body).digest('hex')}`,
      },
      body,
    }),
  );

  expect(ctx.impd.imps.has('pv-0bcd7c17-17')).toBeFalse();
  expect(ctx.store.findPreview({ repo: 'acme/greenhouse', number: 17 })?.phase).toBe('ended');

  expect(issueComments).toStrictEqual([
    {
      id: expect.toBeNumber(),
      repo: 'acme/greenhouse',
      number: 17,
      body: expect.toInclude('**Preview ended.**'),
    },
  ]);
});

test('it removes the imp of a closed pull request it holds no record of, and posts nothing', async () => {
  const ctx = await setupTest();

  ctx.impd.imps.set('pv-0bcd7c17-17', {
    name: 'pv-0bcd7c17-17',
    state: 'sleeping',
    lastActiveAt: null,
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  const body = JSON.stringify({
    action: 'closed',
    number: 17,
    repository: { full_name: 'acme/greenhouse' },
    pull_request: {
      head: {
        sha: '4d2a7c1e9b0f3a5d6c8e7f1a2b3c4d5e6f7a8b9c',
        repo: { full_name: 'acme/greenhouse' },
      },
    },
  });

  await ctx.handler(
    new Request('http://preview.test/webhook', {
      method: 'POST',
      headers: {
        'x-github-event': 'pull_request',
        'x-hub-signature-256': `sha256=${createHmac('sha256', 'stub-webhook-secret').update(body).digest('hex')}`,
      },
      body,
    }),
  );

  expect(ctx.impd.imps.has('pv-0bcd7c17-17')).toBeFalse();
  expect(issueComments).toStrictEqual([]);
});

test('it answers a ping with no change', async () => {
  const ctx = await setupTest();

  const body = JSON.stringify({ zen: 'Keep it logically awesome.', hook_id: 1 });

  const response = await ctx.handler(
    new Request('http://preview.test/webhook', {
      method: 'POST',
      headers: {
        'x-github-event': 'ping',
        'x-hub-signature-256': `sha256=${createHmac('sha256', 'stub-webhook-secret').update(body).digest('hex')}`,
      },
      body,
    }),
  );

  expect(response.status).toBe(204);
  expect(issueComments).toStrictEqual([]);
});

test('it answers 404 on any path but /webhook', async () => {
  const ctx = await setupTest();
  const response = await ctx.handler(new Request('http://preview.test/acme/greenhouse/17'));

  expect(response.status).toBe(404);
});

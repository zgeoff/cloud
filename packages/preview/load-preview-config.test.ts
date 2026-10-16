import { expect, test } from 'bun:test';
import { loadPreviewConfig } from './load-preview-config.ts';

test('it reads the settings from the environment and the secrets from the credential files', async () => {
  const files = new Map([
    ['/run/credentials/preview.service/webhook-secret', 'stub-webhook-secret\n'],
    ['/run/credentials/preview.service/github-token', 'ghp_stub-preview-token\n'],
    ['/run/credentials/preview.service/imp-token', 'imp_stubpreview.stub-secret\n'],
  ]);

  const config = await loadPreviewConfig(
    {
      CREDENTIALS_DIRECTORY: '/run/credentials/preview.service',
      PREVIEW_REPOS: 'acme/greenhouse, nursery/*',
      PREVIEW_BASE_URL: 'http://geoffcloud:8417/',
      PREVIEW_LINK_LISTEN: '100.64.0.10:8417',
      PREVIEW_WEBHOOK_LISTEN: '100.64.0.10:8418',
      PREVIEW_IMPD_URL: 'http://127.0.0.1:7070',
      PREVIEW_IMP_DOMAIN: 'imps.example.test',
      PREVIEW_IMP_IMAGE: 'base',
      PREVIEW_IMP_GITHUB_SECRET: 'gh',
      PREVIEW_DATABASE: '/var/lib/preview/previews.sqlite',
    },
    (path) => Promise.resolve(files.get(path) ?? ''),
  );

  expect(config).toStrictEqual({
    settings: {
      baseURL: 'http://geoffcloud:8417',
      repos: new Set(['acme/greenhouse', 'nursery/*']),
      slots: 1,
      idleMs: 1_800_000,
      impDomain: 'imps.example.test',
      impImage: 'base',
      impMemoryMib: 2048,
      impGitHubSecret: 'gh',
      healthTimeoutMs: 600_000,
      healthPollMs: 2000,
      buildTimeoutMs: 1_800_000,
      contract: null,
    },
    linkListener: { hostname: '100.64.0.10', port: 8417 },
    webhookListener: { hostname: '100.64.0.10', port: 8418 },
    impdURL: 'http://127.0.0.1:7070',
    databasePath: '/var/lib/preview/previews.sqlite',
    webhookSecret: 'stub-webhook-secret',
    githubToken: 'ghp_stub-preview-token',
    impdToken: 'imp_stubpreview.stub-secret',
    sweepIntervalMs: 60_000,
  });
});

test('it rejects an empty credential', () => {
  expect(
    loadPreviewConfig(
      {
        CREDENTIALS_DIRECTORY: '/run/credentials/preview.service',
        PREVIEW_REPOS: 'acme/greenhouse',
        PREVIEW_BASE_URL: 'http://geoffcloud:8417',
        PREVIEW_LINK_LISTEN: '100.64.0.10:8417',
        PREVIEW_WEBHOOK_LISTEN: '100.64.0.10:8418',
        PREVIEW_IMPD_URL: 'http://127.0.0.1:7070',
        PREVIEW_IMP_DOMAIN: 'imps.example.test',
        PREVIEW_IMP_IMAGE: 'base',
        PREVIEW_DATABASE: '/var/lib/preview/previews.sqlite',
      },
      () => Promise.resolve('\n'),
    ),
  ).rejects.toThrowWithMessage(Error, 'the credential webhook-secret is empty');
});

test('it rejects a repository that is not owner/name', () => {
  expect(
    loadPreviewConfig(
      {
        CREDENTIALS_DIRECTORY: '/run/credentials/preview.service',
        PREVIEW_REPOS: 'greenhouse',
        PREVIEW_BASE_URL: 'http://geoffcloud:8417',
        PREVIEW_LINK_LISTEN: '100.64.0.10:8417',
        PREVIEW_WEBHOOK_LISTEN: '100.64.0.10:8418',
        PREVIEW_IMPD_URL: 'http://127.0.0.1:7070',
        PREVIEW_IMP_DOMAIN: 'imps.example.test',
        PREVIEW_IMP_IMAGE: 'base',
        PREVIEW_DATABASE: '/var/lib/preview/previews.sqlite',
      },
      () => Promise.resolve('a-secret'),
    ),
  ).rejects.toThrowWithMessage(
    Error,
    'PREVIEW_REPOS names greenhouse, which is not owner/name or owner/*',
  );
});

test('it rejects a slot count that is not a positive integer', () => {
  expect(
    loadPreviewConfig(
      {
        CREDENTIALS_DIRECTORY: '/run/credentials/preview.service',
        PREVIEW_REPOS: 'acme/greenhouse',
        PREVIEW_BASE_URL: 'http://geoffcloud:8417',
        PREVIEW_LINK_LISTEN: '100.64.0.10:8417',
        PREVIEW_WEBHOOK_LISTEN: '100.64.0.10:8418',
        PREVIEW_IMPD_URL: 'http://127.0.0.1:7070',
        PREVIEW_IMP_DOMAIN: 'imps.example.test',
        PREVIEW_IMP_IMAGE: 'base',
        PREVIEW_DATABASE: '/var/lib/preview/previews.sqlite',
        PREVIEW_SLOTS: '0',
      },
      () => Promise.resolve('a-secret'),
    ),
  ).rejects.toThrowWithMessage(Error, 'PREVIEW_SLOTS is 0, not a positive integer');
});

test('it rejects a listener without a port', () => {
  expect(
    loadPreviewConfig(
      {
        CREDENTIALS_DIRECTORY: '/run/credentials/preview.service',
        PREVIEW_REPOS: 'acme/greenhouse',
        PREVIEW_BASE_URL: 'http://geoffcloud:8417',
        PREVIEW_LINK_LISTEN: '100.64.0.10',
        PREVIEW_WEBHOOK_LISTEN: '100.64.0.10:8418',
        PREVIEW_IMPD_URL: 'http://127.0.0.1:7070',
        PREVIEW_IMP_DOMAIN: 'imps.example.test',
        PREVIEW_IMP_IMAGE: 'base',
        PREVIEW_DATABASE: '/var/lib/preview/previews.sqlite',
      },
      () => Promise.resolve('a-secret'),
    ),
  ).rejects.toThrowWithMessage(Error, '100.64.0.10 is not host:port');
});

test('it reads the SDK contract settings when the environment names a contract repository', async () => {
  const config = await loadPreviewConfig(
    {
      CREDENTIALS_DIRECTORY: '/run/credentials/preview.service',
      PREVIEW_REPOS: 'acme/greenhouse',
      PREVIEW_BASE_URL: 'http://geoffcloud:8417',
      PREVIEW_LINK_LISTEN: '100.64.0.10:8417',
      PREVIEW_WEBHOOK_LISTEN: '100.64.0.10:8418',
      PREVIEW_IMPD_URL: 'http://127.0.0.1:7070',
      PREVIEW_IMP_DOMAIN: 'imps.example.test',
      PREVIEW_IMP_IMAGE: 'base',
      PREVIEW_DATABASE: '/var/lib/preview/previews.sqlite',
      PREVIEW_CONTRACT_REPOS: 'acme/greenhouse, nursery/*',
      PREVIEW_CONTRACT_MODEL_SECRET: 'model-haiku',
      PREVIEW_CONTRACT_TIMEOUT_MINUTES: '15',
    },
    () => Promise.resolve('a-secret'),
  );

  expect(config.settings.contract).toStrictEqual({
    repos: new Set(['acme/greenhouse', 'nursery/*']),
    modelSecret: 'model-haiku',
    timeoutMs: 900_000,
  });
});

test('it gives an SDK contract run ten minutes by default', async () => {
  const config = await loadPreviewConfig(
    {
      CREDENTIALS_DIRECTORY: '/run/credentials/preview.service',
      PREVIEW_REPOS: 'acme/greenhouse',
      PREVIEW_BASE_URL: 'http://geoffcloud:8417',
      PREVIEW_LINK_LISTEN: '100.64.0.10:8417',
      PREVIEW_WEBHOOK_LISTEN: '100.64.0.10:8418',
      PREVIEW_IMPD_URL: 'http://127.0.0.1:7070',
      PREVIEW_IMP_DOMAIN: 'imps.example.test',
      PREVIEW_IMP_IMAGE: 'base',
      PREVIEW_DATABASE: '/var/lib/preview/previews.sqlite',
      PREVIEW_CONTRACT_REPOS: 'acme/greenhouse',
      PREVIEW_CONTRACT_MODEL_SECRET: 'model-haiku',
    },
    () => Promise.resolve('a-secret'),
  );

  expect(config.settings.contract?.timeoutMs).toBe(600_000);
});

test('it rejects contract repositories without a model secret', () => {
  expect(
    loadPreviewConfig(
      {
        CREDENTIALS_DIRECTORY: '/run/credentials/preview.service',
        PREVIEW_REPOS: 'acme/greenhouse',
        PREVIEW_BASE_URL: 'http://geoffcloud:8417',
        PREVIEW_LINK_LISTEN: '100.64.0.10:8417',
        PREVIEW_WEBHOOK_LISTEN: '100.64.0.10:8418',
        PREVIEW_IMPD_URL: 'http://127.0.0.1:7070',
        PREVIEW_IMP_DOMAIN: 'imps.example.test',
        PREVIEW_IMP_IMAGE: 'base',
        PREVIEW_DATABASE: '/var/lib/preview/previews.sqlite',
        PREVIEW_CONTRACT_REPOS: 'acme/greenhouse',
      },
      () => Promise.resolve('a-secret'),
    ),
  ).rejects.toThrowWithMessage(Error, 'PREVIEW_CONTRACT_MODEL_SECRET is not set');
});

test('it rejects a contract repository that is not owner/name', () => {
  expect(
    loadPreviewConfig(
      {
        CREDENTIALS_DIRECTORY: '/run/credentials/preview.service',
        PREVIEW_REPOS: 'acme/greenhouse',
        PREVIEW_BASE_URL: 'http://geoffcloud:8417',
        PREVIEW_LINK_LISTEN: '100.64.0.10:8417',
        PREVIEW_WEBHOOK_LISTEN: '100.64.0.10:8418',
        PREVIEW_IMPD_URL: 'http://127.0.0.1:7070',
        PREVIEW_IMP_DOMAIN: 'imps.example.test',
        PREVIEW_IMP_IMAGE: 'base',
        PREVIEW_DATABASE: '/var/lib/preview/previews.sqlite',
        PREVIEW_CONTRACT_REPOS: 'greenhouse',
        PREVIEW_CONTRACT_MODEL_SECRET: 'model-haiku',
      },
      () => Promise.resolve('a-secret'),
    ),
  ).rejects.toThrowWithMessage(
    Error,
    'PREVIEW_CONTRACT_REPOS names greenhouse, which is not owner/name or owner/*',
  );
});

test('it rejects a missing setting', () => {
  expect(
    loadPreviewConfig({ CREDENTIALS_DIRECTORY: '/run/credentials/preview.service' }, () =>
      Promise.resolve('a-secret'),
    ),
  ).rejects.toThrowWithMessage(Error, 'PREVIEW_BASE_URL is not set');
});

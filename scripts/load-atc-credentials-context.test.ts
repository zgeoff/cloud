import { expect, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { loadATCCredentialsContext } from './load-atc-credentials-context.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'load-atc-credentials-context-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  return { directory, run: buildStubRunner().run };
}

test('it takes the production host, vault, item, directory and impd port by default', async () => {
  const ctx = await setupTest();

  const context = await loadATCCredentialsContext({
    run: ctx.run,
    env: { OP_SERVICE_ACCOUNT_TOKEN: 'ops_fixture_env' },
    printOut: () => {},
    printErr: () => {},
  });

  expect(context).toStrictEqual({
    run: ctx.run,
    printOut: expect.toBeFunction(),
    printErr: expect.toBeFunction(),
    host: 'geoffcloud',
    vault: 'cloud',
    item: 'atc-daemon-token',
    directory: '/var/lib/atc-daemon-secrets',
    impdPort: '7070',
    opEnv: { OP_SERVICE_ACCOUNT_TOKEN: 'ops_fixture_env' },
  });
});

test('it takes each setting the environment names', async () => {
  const ctx = await setupTest();

  const context = await loadATCCredentialsContext({
    run: ctx.run,
    env: {
      OP_SERVICE_ACCOUNT_TOKEN: 'ops_fixture_env',
      ATC_CREDENTIALS_HOST: 'canary',
      ATC_CREDENTIALS_VAULT: 'staging',
      ATC_DAEMON_TOKEN_ITEM: 'canary-token',
      ATC_CREDENTIALS_DIR: '/srv/atc secrets',
      ATC_IMPD_PORT: '7171',
    },
    printOut: () => {},
    printErr: () => {},
  });

  expect(context).toMatchObject({
    host: 'canary',
    vault: 'staging',
    item: 'canary-token',
    directory: '/srv/atc secrets',
    impdPort: '7171',
  });
});

test('it reads the 1Password token from the cloud checkout’s settings file when the environment has none', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.directory, 'projects/cloud/.claude'), { recursive: true });

  await writeFile(
    join(ctx.directory, 'projects/cloud/.claude/settings.local.json'),
    '{"env":{"OP_SERVICE_ACCOUNT_TOKEN":"ops_fixture_settings"}}',
  );

  const context = await loadATCCredentialsContext({
    run: ctx.run,
    env: { HOME: ctx.directory },
    printOut: () => {},
    printErr: () => {},
  });

  expect(context.opEnv).toStrictEqual({
    HOME: ctx.directory,
    OP_SERVICE_ACCOUNT_TOKEN: 'ops_fixture_settings',
  });
});

test('it reads the 1Password token from the settings file the environment names', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.directory, 'settings.json'),
    '{"env":{"OP_SERVICE_ACCOUNT_TOKEN":"ops_fixture_named"}}',
  );

  const context = await loadATCCredentialsContext({
    run: ctx.run,
    env: {
      HOME: join(ctx.directory, 'home'),
      CLOUD_OP_SETTINGS: join(ctx.directory, 'settings.json'),
    },
    printOut: () => {},
    printErr: () => {},
  });

  expect(context.opEnv['OP_SERVICE_ACCOUNT_TOKEN']).toBe('ops_fixture_named');
});

test('it stops with exit 2 when the settings file is missing and the environment has no token', async () => {
  const ctx = await setupTest();

  expect(
    loadATCCredentialsContext({
      run: ctx.run,
      env: { HOME: ctx.directory },
      printOut: () => {},
      printErr: () => {},
    }),
  ).rejects.toMatchObject({
    exitCode: 2,
    message: `cannot read ${ctx.directory}/projects/cloud/.claude/settings.local.json (ENOENT); nothing changed`,
  });
});

test.each([
  ['no token', '{"env":{}}'],
  ['an empty token', '{"env":{"OP_SERVICE_ACCOUNT_TOKEN":""}}'],
  ['no env object', '[]'],
])('it stops when the settings file holds %s', async (_label: string, settings: string) => {
  const ctx = await setupTest();

  await writeFile(join(ctx.directory, 'settings.json'), settings);

  expect(
    loadATCCredentialsContext({
      run: ctx.run,
      env: { CLOUD_OP_SETTINGS: join(ctx.directory, 'settings.json') },
      printOut: () => {},
      printErr: () => {},
    }),
  ).rejects.toMatchObject({
    exitCode: 1,
    message: `${ctx.directory}/settings.json holds no env.OP_SERVICE_ACCOUNT_TOKEN; nothing changed`,
  });
});

test('it stops when the settings file is not JSON', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.directory, 'settings.json'), 'not json');

  expect(
    loadATCCredentialsContext({
      run: ctx.run,
      env: { CLOUD_OP_SETTINGS: join(ctx.directory, 'settings.json') },
      printOut: () => {},
      printErr: () => {},
    }),
  ).rejects.toMatchObject({ exitCode: 1, message: `no JSON from ${ctx.directory}/settings.json` });
});

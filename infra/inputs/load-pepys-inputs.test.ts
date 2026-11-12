import { expect, test } from 'bun:test';
import { Output, isSecret } from '@pulumi/pulumi';
import invariant from 'tiny-invariant';
import { buildStubConfig } from '../test-utils/build-stub-config.ts';
import { resolveOutput } from '../test-utils/resolve-output.ts';
import { loadPepysInputs } from './load-pepys-inputs.ts';

function setupTest() {
  const image =
    'ghcr.io/zgeoff/cloud-pepys:0.4.0-3f9c1d2a7b10@sha256:4444444444444444444444444444444444444444444444444444444444444444';

  const pepysConfig = buildStubConfig({
    pepys: JSON.stringify({
      image,
      webhookHostname: 'pepys-webhook.geoff.cloud',
      impIdentityAudience: 'pepys-telemetry-for-tests',
    }),
  });

  const coreEnv = {
    GHCR_PULL_USERNAME: 'octo-puller',
    GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
    PEPYS_GARAGE_RPC_SECRET: 'rpc-secret-for-tests',
    PEPYS_GARAGE_ADMIN_TOKEN: 'admin-token-for-tests',
    PEPYS_S2_GARAGE_ACCESS_KEY_ID: 'GK0123456789abcdef01234567',
    PEPYS_S2_GARAGE_SECRET_ACCESS_KEY:
      '89abcdef0123456789abcdef0123456789abcdef0123456789abcdef01234567',
    PEPYS_S2_ACCESS_TOKEN: 's2-token-for-tests',
    PEPYS_WIDGET_SECRET: 'widget-secret-for-tests',
  };

  const backupEnv = {
    PEPYS_BACKUP_GARAGE_ACCESS_KEY_ID: 'GK-backup-key-for-tests',
    PEPYS_BACKUP_GARAGE_SECRET_ACCESS_KEY: 'backup-garage-secret-for-tests',
    PEPYS_R2_ENDPOINT: 'https://r2.example.test',
    PEPYS_R2_BUCKET: 'pepys-backup-for-tests',
    PEPYS_R2_ACCESS_KEY_ID: 'r2-key-for-tests',
    PEPYS_R2_SECRET_ACCESS_KEY: 'r2-secret-for-tests',
  };

  return {
    image,
    pepysConfig,
    coreEnv,
    backupEnv,
    isOutput: (value: unknown) => Output.isInstance(value),
  };
}

test('it leaves the audience out while the stack config names none', () => {
  const fixture = setupTest();

  const config = buildStubConfig({
    pepys: JSON.stringify({ image: fixture.image, webhookHostname: 'pepys-webhook.geoff.cloud' }),
  });

  expect(
    loadPepysInputs(config, fixture.coreEnv, ['PEPYS_WIDGET_SECRET']).pepys?.config,
  ).toStrictEqual({
    image: fixture.image,
    webhookHostname: 'pepys-webhook.geoff.cloud',
  });
});

test('it returns nothing while the stack config leaves pepys out', () => {
  const fixture = setupTest();

  expect(
    loadPepysInputs(buildStubConfig({}), fixture.coreEnv, ['PEPYS_WIDGET_SECRET']),
  ).toStrictEqual({});
});

test('it returns the config, the pull credential and one secret per variable, with no backup while its variables are unset', () => {
  const fixture = setupTest();

  expect(
    loadPepysInputs(fixture.pepysConfig, fixture.coreEnv, ['PEPYS_WIDGET_SECRET']),
  ).toStrictEqual({
    pepys: {
      config: {
        image: fixture.image,
        webhookHostname: 'pepys-webhook.geoff.cloud',
        impIdentityAudience: 'pepys-telemetry-for-tests',
      },
      pullCredential: { username: 'octo-puller', token: expect.toSatisfy(fixture.isOutput) },
      secrets: {
        garageRPCSecret: expect.toSatisfy(fixture.isOutput),
        garageAdminToken: expect.toSatisfy(fixture.isOutput),
        s2GarageAccessKeyID: expect.toSatisfy(fixture.isOutput),
        s2GarageSecretAccessKey: expect.toSatisfy(fixture.isOutput),
        s2AccessToken: expect.toSatisfy(fixture.isOutput),
        ingest: { PEPYS_WIDGET_SECRET: expect.toSatisfy(fixture.isOutput) },
      },
    },
  });
});

test('it marks each ingest secret secret and carries its value', async () => {
  const fixture = setupTest();
  const inputs = loadPepysInputs(fixture.pepysConfig, fixture.coreEnv, ['PEPYS_WIDGET_SECRET']);

  invariant(inputs.pepys);

  const value = inputs.pepys.secrets.ingest['PEPYS_WIDGET_SECRET'];

  invariant(value);

  const secretValue = await isSecret(value);
  const resolved = await resolveOutput(value);

  expect(secretValue).toBeTrue();
  expect(resolved).toBe('widget-secret-for-tests');
});

test('it refuses a missing ingest secret by its name', () => {
  const fixture = setupTest();

  expect(() =>
    loadPepysInputs(fixture.pepysConfig, fixture.coreEnv, ['PEPYS_OTHER_SECRET']),
  ).toThrowWithMessage(
    Error,
    'PEPYS_OTHER_SECRET is unset; pepys needs it while stack config "pepys" is set',
  );
});

test('it refuses an image without a digest', () => {
  const fixture = setupTest();

  expect(() =>
    loadPepysInputs(
      buildStubConfig({
        pepys: JSON.stringify({
          image: 'ghcr.io/zgeoff/cloud-pepys:0.4.0',
          webhookHostname: 'pepys-webhook.geoff.cloud',
          impIdentityAudience: 'pepys-telemetry-for-tests',
        }),
      }),
      fixture.coreEnv,
      [],
    ),
  ).toThrowWithMessage(Error, 'stack config "pepys.image" must name an image by tag and digest');
});

test('it adds the backup when every backup variable is set', async () => {
  const fixture = setupTest();

  const inputs = loadPepysInputs(
    fixture.pepysConfig,
    { ...fixture.coreEnv, ...fixture.backupEnv },
    [],
  );

  invariant(inputs.pepys?.backup);

  const bucket = await resolveOutput(inputs.pepys.backup.secrets.r2Bucket);

  expect(bucket).toBe('pepys-backup-for-tests');
});

test('it refuses a backup with one variable unset, and names it', () => {
  const fixture = setupTest();
  const { PEPYS_R2_BUCKET: _, ...partial } = fixture.backupEnv;

  expect(() =>
    loadPepysInputs(fixture.pepysConfig, { ...fixture.coreEnv, ...partial }, []),
  ).toThrowWithMessage(Error, /unset: PEPYS_R2_BUCKET$/u);
});

test('it refuses an R2 endpoint with a path', () => {
  const fixture = setupTest();

  expect(() =>
    loadPepysInputs(
      fixture.pepysConfig,
      {
        ...fixture.coreEnv,
        ...fixture.backupEnv,
        PEPYS_R2_ENDPOINT: 'https://r2.example.test/bucket',
      },
      [],
    ),
  ).toThrowWithMessage(Error, 'PEPYS_R2_ENDPOINT must be an https:// origin with no path');
});

test('it refuses an s2-lite key that Garage would not import', () => {
  const fixture = setupTest();

  expect(() =>
    loadPepysInputs(
      fixture.pepysConfig,
      { ...fixture.coreEnv, PEPYS_S2_GARAGE_ACCESS_KEY_ID: 'AKIA0123456789' },
      [],
    ),
  ).toThrowWithMessage(Error, /^PEPYS_S2_GARAGE_ACCESS_KEY_ID must be GK and 24 hex digits/u);
});

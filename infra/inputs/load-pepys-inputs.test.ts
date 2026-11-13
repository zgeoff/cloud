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

// 0.10.0 sorts below 0.3.0 as text, so it fails a check that compares the tag as a string
test.each(['0.3.0', '0.3.1', '0.10.0', '1.0.0'])(
  'it carries the API hostname on an image of pepys %s',
  (release: string) => {
    const fixture = setupTest();
    const image = `ghcr.io/zgeoff/cloud-pepys:${release}-3f9c1d2a7b10@sha256:4444444444444444444444444444444444444444444444444444444444444444`;

    const config = buildStubConfig({
      pepys: JSON.stringify({
        image,
        webhookHostname: 'pepys-webhook.geoff.cloud',
        apiHostname: 'pepys.geoff.cloud',
      }),
    });

    expect(
      loadPepysInputs(config, fixture.coreEnv, ['PEPYS_WIDGET_SECRET']).pepys?.config,
    ).toStrictEqual({
      image,
      webhookHostname: 'pepys-webhook.geoff.cloud',
      apiHostname: 'pepys.geoff.cloud',
    });
  },
);

test.each([
  [
    'pepys 0.2.0',
    'ghcr.io/zgeoff/cloud-pepys:0.2.0-9c1b151f62c7@sha256:4444444444444444444444444444444444444444444444444444444444444444',
  ],
  [
    'pepys 0.2.9',
    'ghcr.io/zgeoff/cloud-pepys:0.2.9-9c1b151f62c7@sha256:4444444444444444444444444444444444444444444444444444444444444444',
  ],
])(
  'it refuses the API hostname on an image of %s, whose API serves /mcp to any caller',
  (release: string, image: string) => {
    const fixture = setupTest();

    expect(() =>
      loadPepysInputs(
        buildStubConfig({
          pepys: JSON.stringify({
            image,
            webhookHostname: 'pepys-webhook.geoff.cloud',
            apiHostname: 'pepys.geoff.cloud',
          }),
        }),
        fixture.coreEnv,
        [],
      ),
    ).toThrowWithMessage(
      Error,
      `stack config "pepys.apiHostname" needs a "pepys.image" of pepys 0.3.0 or later, whose API checks a token on /mcp; the image is ${release}`,
    );
  },
);

test('it refuses the API hostname on an image whose tag names no release', () => {
  const fixture = setupTest();

  expect(() =>
    loadPepysInputs(
      buildStubConfig({
        pepys: JSON.stringify({
          image:
            'ghcr.io/zgeoff/cloud-pepys:latest@sha256:4444444444444444444444444444444444444444444444444444444444444444',
          webhookHostname: 'pepys-webhook.geoff.cloud',
          apiHostname: 'pepys.geoff.cloud',
        }),
      }),
      fixture.coreEnv,
      [],
    ),
  ).toThrowWithMessage(
    Error,
    'stack config "pepys.apiHostname" needs a "pepys.image" of pepys 0.3.0 or later, whose API checks a token on /mcp; the image is not a release tag',
  );
});

test("it refuses an API hostname equal to ingest's webhook hostname", () => {
  const fixture = setupTest();

  expect(() =>
    loadPepysInputs(
      buildStubConfig({
        pepys: JSON.stringify({
          image: fixture.image,
          webhookHostname: 'pepys-webhook.geoff.cloud',
          apiHostname: 'pepys-webhook.geoff.cloud',
        }),
      }),
      fixture.coreEnv,
      [],
    ),
  ).toThrowWithMessage(
    Error,
    'stack config "pepys.apiHostname" must differ from "pepys.webhookHostname"',
  );
});

test('it refuses an API hostname outside geoff.cloud', () => {
  const fixture = setupTest();

  expect(() =>
    loadPepysInputs(
      buildStubConfig({
        pepys: JSON.stringify({
          image: fixture.image,
          webhookHostname: 'pepys-webhook.geoff.cloud',
          apiHostname: 'pepys.example.test',
        }),
      }),
      fixture.coreEnv,
      [],
    ),
  ).toThrowWithMessage(
    Error,
    'stack config "pepys.apiHostname" must name a host under geoff.cloud',
  );
});

test('it carries the tailnet hostname that the exposure registry lists', () => {
  const fixture = setupTest();

  const config = buildStubConfig({
    pepys: JSON.stringify({
      image: fixture.image,
      webhookHostname: 'pepys-webhook.geoff.cloud',
      tailnetHostname: 'pepys-api.geoff.cloud',
    }),
  });

  expect(
    loadPepysInputs(config, fixture.coreEnv, ['PEPYS_WIDGET_SECRET']).pepys?.config,
  ).toStrictEqual({
    image: fixture.image,
    webhookHostname: 'pepys-webhook.geoff.cloud',
    tailnetHostname: 'pepys-api.geoff.cloud',
  });
});

test.each([
  [
    'outside geoff.cloud',
    'pepys-api.example.test',
    'stack config "pepys.tailnetHostname" must name a host under geoff.cloud',
  ],
  [
    "equal to the API's public hostname",
    'pepys.geoff.cloud',
    'stack config "pepys.tailnetHostname" must differ from "pepys.webhookHostname" and "pepys.apiHostname"',
  ],
  [
    "equal to ingest's webhook hostname",
    'pepys-webhook.geoff.cloud',
    'stack config "pepys.tailnetHostname" must differ from "pepys.webhookHostname" and "pepys.apiHostname"',
  ],
  [
    'that the exposure registry does not list',
    'pepys-rpc.geoff.cloud',
    'stack config "pepys.tailnetHostname" needs a tailnet-hostname entry for pepys-rpc.geoff.cloud in packages/topology/exposure.json',
  ],
])('it refuses a tailnet hostname %s', (_label: string, hostname: string, message: string) => {
  const fixture = setupTest();

  expect(() =>
    loadPepysInputs(
      buildStubConfig({
        pepys: JSON.stringify({
          image: fixture.image,
          webhookHostname: 'pepys-webhook.geoff.cloud',
          apiHostname: 'pepys.geoff.cloud',
          tailnetHostname: hostname,
        }),
      }),
      fixture.coreEnv,
      [],
    ),
  ).toThrowWithMessage(Error, message);
});

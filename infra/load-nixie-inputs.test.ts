import { expect, test } from 'bun:test';
import { Output, isSecret } from '@pulumi/pulumi';
import { loadNixieInputs } from './load-nixie-inputs.ts';
import { buildStubConfig } from './test-utils/build-stub-config.ts';
import { resolveOutput } from './test-utils/resolve-output.ts';

test('it returns nothing while the stack config leaves nixie out', () => {
  expect(
    loadNixieInputs(buildStubConfig({}), {
      NIXIE_AGE_HOST_KEY: 'AGE-SECRET-KEY-1QQQ',
      NIXIE_DEFINITIONS_DEPLOY_KEY: 'deploy-key',
      CLOUDFLARE_API_TOKEN: 'cf-token',
    }),
  ).toStrictEqual({});
});

test('it returns the pinned images, the host name and the 3 secrets when nixie is set', () => {
  const stackConfig = buildStubConfig({
    nixie: JSON.stringify({
      image:
        'ghcr.io/zgeoff/nixie:0.1.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
      webImage:
        'ghcr.io/zgeoff/nixie-web:0.1.0@sha256:318c0b6c6ff89e0b0bbd252df2d04b0120ef28c7266d698ffa9757ff4d2f5754',
      hostname: 'nixie.geoff.cloud',
    }),
  });

  expect(
    loadNixieInputs(stackConfig, {
      NIXIE_AGE_HOST_KEY: 'AGE-SECRET-KEY-1QQQ',
      NIXIE_DEFINITIONS_DEPLOY_KEY: 'deploy-key',
      CLOUDFLARE_API_TOKEN: 'cf-token',
    }),
  ).toStrictEqual({
    nixie: {
      config: {
        image:
          'ghcr.io/zgeoff/nixie:0.1.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
        webImage:
          'ghcr.io/zgeoff/nixie-web:0.1.0@sha256:318c0b6c6ff89e0b0bbd252df2d04b0120ef28c7266d698ffa9757ff4d2f5754',
        hostname: 'nixie.geoff.cloud',
      },
      secrets: {
        ageHostKey: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
        definitionsDeployKey: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
        dnsToken: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
      },
    },
  });
});

test.each([
  ['ageHostKey', 'AGE-SECRET-KEY-1QQQ'],
  ['definitionsDeployKey', 'deploy-key'],
  ['dnsToken', 'cf-token'],
] as const)('it marks %s secret and carries its value as given', async (name, expected) => {
  const inputs = loadNixieInputs(
    buildStubConfig({
      nixie: JSON.stringify({
        image:
          'ghcr.io/zgeoff/nixie:0.1.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
        webImage:
          'ghcr.io/zgeoff/nixie-web:0.1.0@sha256:318c0b6c6ff89e0b0bbd252df2d04b0120ef28c7266d698ffa9757ff4d2f5754',
        hostname: 'nixie.geoff.cloud',
      }),
    }),
    {
      NIXIE_AGE_HOST_KEY: 'AGE-SECRET-KEY-1QQQ',
      NIXIE_DEFINITIONS_DEPLOY_KEY: 'deploy-key',
      CLOUDFLARE_API_TOKEN: 'cf-token',
    },
  );

  if (inputs.nixie === undefined) {
    throw new Error('expected the nixie inputs');
  }

  const isMarkedSecret = await isSecret(inputs.nixie.secrets[name]);
  const value = await resolveOutput(inputs.nixie.secrets[name]);

  expect(isMarkedSecret).toBeTrue();
  expect(value).toBe(expected);
});

test.each([
  ['NIXIE_AGE_HOST_KEY'],
  ['NIXIE_DEFINITIONS_DEPLOY_KEY'],
  ['CLOUDFLARE_API_TOKEN'],
] as const)('it throws when %s is unset while nixie is set', (name) => {
  const env: Record<string, string | undefined> = {
    NIXIE_AGE_HOST_KEY: 'AGE-SECRET-KEY-1QQQ',
    NIXIE_DEFINITIONS_DEPLOY_KEY: 'deploy-key',
    CLOUDFLARE_API_TOKEN: 'cf-token',
    [name]: undefined,
  };

  expect(() =>
    loadNixieInputs(
      buildStubConfig({
        nixie: JSON.stringify({
          image:
            'ghcr.io/zgeoff/nixie:0.1.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
          webImage:
            'ghcr.io/zgeoff/nixie-web:0.1.0@sha256:318c0b6c6ff89e0b0bbd252df2d04b0120ef28c7266d698ffa9757ff4d2f5754',
          hostname: 'nixie.geoff.cloud',
        }),
      }),
      env,
    ),
  ).toThrowWithMessage(Error, `${name} is unset; nixie needs it while stack config "nixie" is set`);
});

test.each([
  ['image', 'a tag alone', 'ghcr.io/zgeoff/nixie:0.1.0'],
  [
    'image',
    'a digest alone',
    'ghcr.io/zgeoff/nixie@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
  ],
  ['webImage', 'a tag alone', 'ghcr.io/zgeoff/nixie-web:0.1.0'],
] as const)('it throws when %s names %s', (key, _label, image) => {
  const config: Record<string, string> = {
    image:
      'ghcr.io/zgeoff/nixie:0.1.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
    webImage:
      'ghcr.io/zgeoff/nixie-web:0.1.0@sha256:318c0b6c6ff89e0b0bbd252df2d04b0120ef28c7266d698ffa9757ff4d2f5754',
    hostname: 'nixie.geoff.cloud',
    [key]: image,
  };

  expect(() =>
    loadNixieInputs(buildStubConfig({ nixie: JSON.stringify(config) }), {
      NIXIE_AGE_HOST_KEY: 'AGE-SECRET-KEY-1QQQ',
      NIXIE_DEFINITIONS_DEPLOY_KEY: 'deploy-key',
      CLOUDFLARE_API_TOKEN: 'cf-token',
    }),
  ).toThrowWithMessage(Error, `stack config "nixie.${key}" must name an image by tag and digest`);
});

test.each([
  ['no host name', undefined],
  ['a host outside geoff.cloud', 'nixie.example.com'],
  ['the zone apex', 'geoff.cloud'],
  ['a name with a space', 'nixie .geoff.cloud'],
] as const)('it throws when the hostname is %s', (_label, hostname) => {
  expect(() =>
    loadNixieInputs(
      buildStubConfig({
        nixie: JSON.stringify({
          image:
            'ghcr.io/zgeoff/nixie:0.1.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
          webImage:
            'ghcr.io/zgeoff/nixie-web:0.1.0@sha256:318c0b6c6ff89e0b0bbd252df2d04b0120ef28c7266d698ffa9757ff4d2f5754',
          hostname,
        }),
      }),
      {
        NIXIE_AGE_HOST_KEY: 'AGE-SECRET-KEY-1QQQ',
        NIXIE_DEFINITIONS_DEPLOY_KEY: 'deploy-key',
        CLOUDFLARE_API_TOKEN: 'cf-token',
      },
    ),
  ).toThrowWithMessage(Error, 'stack config "nixie.hostname" must name a host under geoff.cloud');
});

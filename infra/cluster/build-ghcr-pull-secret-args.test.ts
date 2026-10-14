import { expect, test } from 'bun:test';
import { Output, isSecret, output, secret } from '@pulumi/pulumi';
import { resolveOutput } from '../test-utils/resolve-output.ts';
import { buildGHCRPullSecretArgs } from './build-ghcr-pull-secret-args.ts';

test('it names the Secret ghcr-pull in the namespace it is given, as a dockerconfigjson', () => {
  const namespace = output('atc');

  expect(
    buildGHCRPullSecretArgs(namespace, {
      username: 'octo-puller',
      token: secret('ghp_fake0token0for0tests0only0000000000'),
    }),
  ).toStrictEqual({
    metadata: { name: 'ghcr-pull', namespace },
    type: 'kubernetes.io/dockerconfigjson',
    stringData: {
      '.dockerconfigjson': expect.toSatisfy((value: unknown) => Output.isInstance(value)),
    },
  });
});

test("it writes the credential as ghcr.io's basic auth in the docker config", async () => {
  const args = buildGHCRPullSecretArgs(output('atc'), {
    username: 'octo-puller',
    token: secret('ghp_fake0token0for0tests0only0000000000'),
  });

  const json = await resolveOutput(args.stringData['.dockerconfigjson']);

  expect(JSON.parse(json)).toStrictEqual({
    auths: {
      'ghcr.io': {
        username: 'octo-puller',
        password: 'ghp_fake0token0for0tests0only0000000000',
        auth: Buffer.from('octo-puller:ghp_fake0token0for0tests0only0000000000').toString('base64'),
      },
    },
  });
});

test('it keeps the docker config secret, as the token is', () => {
  const args = buildGHCRPullSecretArgs(output('atc'), {
    username: 'octo-puller',
    token: secret('ghp_fake0token0for0tests0only0000000000'),
  });

  expect(isSecret(args.stringData['.dockerconfigjson'])).resolves.toBeTrue();
});

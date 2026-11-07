import { expect, onTestFinished, test } from 'bun:test';
import { output, runtime } from '@pulumi/pulumi';
import { buildStubResourceMocks } from '../test-utils/build-stub-resource-mocks.ts';
import { createClusterProvider } from './create-cluster-provider.ts';
import { createNixie } from './nixie.ts';

async function setupTest() {
  // a held registration stands in for a sandbox image add or a roll that has not finished
  const stub = buildStubResourceMocks(
    ['command:local:Command::nixie-sandbox-images', 'kubernetes:apps/v1:StatefulSet::nixie'],
    {
      'acme:index/certificate:Certificate::nixie': {
        certificatePem: 'leaf-pem',
        issuerPem: 'issuer-pem',
      },
    },
  );

  await runtime.setMocks(stub.mocks, 'geoff-cloud', 'test');

  onTestFinished(() => {
    stub.release();
    runtime.resetOptions('', '', -1, '', '', false, '');
  });

  return {
    stub,
    cluster: createClusterProvider('k3s', { kubeconfig: output('kubeconfig-for-tests') }),
  };
}

test('it registers none of the config, the definitions key and the Secret that nixie mounts while the sandbox image Command has not finished', async () => {
  const ctx = await setupTest();

  createNixie(
    ctx.cluster,
    {
      config: {
        image:
          'ghcr.io/zgeoff/nixie:0.43.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
        webImage:
          'ghcr.io/zgeoff/nixie-web:0.43.0@sha256:1111111111111111111111111111111111111111111111111111111111111111',
        hostname: 'chat.example.test',
      },
      secrets: {
        ageHostKey: output('AGE-SECRET-KEY-FAKE0FOR0TESTS'),
        definitionsDeployKey: output('fake-deploy-key'),
        dnsToken: output('fake-dns-token'),
      },
    },
    { zoneID: output('zone'), kubeconfig: output('kubeconfig-for-tests') },
  );

  await ctx.stub.whenRegistered('command:local:Command::nixie-sandbox-images');
  await ctx.stub.whenRegistered('kubernetes:networking.k8s.io/v1:Ingress::nixie');

  expect(ctx.stub.registered).not.toIncludeAnyMembers([
    'kubernetes:core/v1:ConfigMap::nixie-config',
    'kubernetes:core/v1:Secret::nixie-definitions-key',
    'kubernetes:core/v1:Secret::nixie-secrets',
  ]);
});

test("it registers no copy of the config for the backup's restore while nixie's StatefulSet has not rolled", async () => {
  const ctx = await setupTest();

  createNixie(
    ctx.cluster,
    {
      config: {
        image:
          'ghcr.io/zgeoff/nixie:0.43.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
        webImage:
          'ghcr.io/zgeoff/nixie-web:0.43.0@sha256:1111111111111111111111111111111111111111111111111111111111111111',
        hostname: 'chat.example.test',
      },
      secrets: {
        ageHostKey: output('AGE-SECRET-KEY-FAKE0FOR0TESTS'),
        definitionsDeployKey: output('fake-deploy-key'),
        dnsToken: output('fake-dns-token'),
      },
      backup: {
        image:
          'ghcr.io/zgeoff/nixie-backup:0.43.0@sha256:2222222222222222222222222222222222222222222222222222222222222222',
        pullCredential: { username: 'octo-puller', token: output('fake-pull-token') },
        secrets: {
          dataRepository: output('s3:https://r2.example.test/data'),
          dataPassword: output('fake-data-password'),
          keyRepository: output('s3:https://r2.example.test/keys'),
          keyPassword: output('fake-key-password'),
          accessKeyID: output('fake-access-key-id'),
          secretAccessKey: output('fake-secret-access-key'),
        },
      },
    },
    { zoneID: output('zone'), kubeconfig: output('kubeconfig-for-tests') },
  );

  ctx.stub.releaseKey('command:local:Command::nixie-sandbox-images');

  await ctx.stub.whenRegistered('kubernetes:apps/v1:StatefulSet::nixie');
  await ctx.stub.whenRegistered('kubernetes:networking.k8s.io/v1:Ingress::nixie');

  expect(ctx.stub.registered).not.toContain('kubernetes:core/v1:ConfigMap::nixie-backup-config');
});

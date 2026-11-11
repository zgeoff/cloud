import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildPepysHostSpec } from './build-pepys-host-spec.ts';

function setupTest() {
  const envSecret = output('pepys-host-0a1b2c3d');

  const spec = buildPepysHostSpec({
    image:
      'ghcr.io/zgeoff/cloud-pepys:0.4.0-3f9c1d2a7b10@sha256:4444444444444444444444444444444444444444444444444444444444444444',
    serviceName: output('pepys-host'),
    envSecret,
    pullSecret: 'ghcr-pull',
  });

  return { envSecret, spec };
}

test('it starts the host with run --up on the listed consumers, beside the API in one pod', () => {
  const fixture = setupTest();

  expect(fixture.spec.replicas).toBe(1);

  expect(fixture.spec.template.spec?.containers[0]).toMatchObject({
    name: 'host',
    command: ['/usr/local/bin/pepys-host', 'run', '--up'],
    env: [
      { name: 'PEPYS_S2_ENDPOINT', value: 'http://pepys-s2.pepys.svc.cluster.local:8080' },
      { name: 'PEPYS_S2_BASIN', value: 'pepys-facts' },
      { name: 'PEPYS_STORE_DIR', value: '/store' },
      { name: 'PEPYS_CONSUMERS', value: '/modules/consumers.json' },
    ],
    envFrom: [{ secretRef: { name: fixture.envSecret } }],
  });
});

test('it starts the API on every address, on the store the host writes, with no secret', () => {
  const fixture = setupTest();
  const api = fixture.spec.template.spec?.containers[1];

  expect(api).toMatchObject({
    name: 'api',
    command: ['/usr/local/bin/pepys-api'],
    env: [
      { name: 'PEPYS_STORE_DIR', value: '/store' },
      { name: 'PEPYS_API_HOST', value: '0.0.0.0' },
      { name: 'PEPYS_API_PORT', value: '8081' },
    ],
    volumeMounts: [
      { name: 'store', mountPath: '/store' },
      { name: 'tmp', mountPath: '/tmp' },
    ],
  });

  expect(api?.envFrom).toBeUndefined();
});

test('it keeps the store on a retained 10 GiB volume', () => {
  const fixture = setupTest();

  expect(fixture.spec.volumeClaimTemplates).toStrictEqual([
    {
      metadata: { name: 'store' },
      spec: {
        accessModes: ['ReadWriteOnce'],
        storageClassName: 'local-path-retain',
        resources: { requests: { storage: '10Gi' } },
      },
    },
  ]);
});

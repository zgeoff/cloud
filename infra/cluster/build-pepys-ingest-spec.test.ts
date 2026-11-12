import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildPepysIngestSpec } from './build-pepys-ingest-spec.ts';

test('it starts ingest on every address, with the s2-lite Service, the sender proof settings and its secrets', () => {
  const envSecret = output('pepys-ingest-0a1b2c3d');
  const issuersConfigMap = output('pepys-imp-issuers-0a1b2c3d');

  const spec = buildPepysIngestSpec({
    image:
      'ghcr.io/zgeoff/cloud-pepys:0.4.0-3f9c1d2a7b10@sha256:4444444444444444444444444444444444444444444444444444444444444444',
    impIdentityAudience: 'pepys-telemetry-for-tests',
    envSecret,
    issuersConfigMap,
    pullSecret: 'ghcr-pull',
  });

  expect(spec.template.spec?.imagePullSecrets).toStrictEqual([{ name: 'ghcr-pull' }]);

  expect(spec.template.spec?.volumes).toContainEqual({
    name: 'imp-issuers',
    configMap: { name: issuersConfigMap },
  });

  expect(spec.template.spec?.containers[0]).toMatchObject({
    command: ['/usr/local/bin/pepys-ingest'],
    env: [
      { name: 'PEPYS_INGEST_HOST', value: '0.0.0.0' },
      { name: 'PEPYS_INGEST_PORT', value: '8080' },
      { name: 'PEPYS_S2_ENDPOINT', value: 'http://pepys-s2.pepys.svc.cluster.local:8080' },
      { name: 'PEPYS_S2_BASIN', value: 'pepys-facts' },
      { name: 'PEPYS_IMP_IDENTITY_AUDIENCE', value: 'pepys-telemetry-for-tests' },
      { name: 'PEPYS_IMP_IDENTITY_ISSUERS', value: '/etc/pepys/imp-issuers' },
    ],
    envFrom: [{ secretRef: { name: envSecret } }],
    readinessProbe: { tcpSocket: { port: 8080 } },
  });
});

test('it sets no audience while the stack config names none, so ingest starts and refuses every telemetry export', () => {
  const spec = buildPepysIngestSpec({
    image:
      'ghcr.io/zgeoff/cloud-pepys:0.4.0-3f9c1d2a7b10@sha256:4444444444444444444444444444444444444444444444444444444444444444',
    envSecret: output('pepys-ingest-0a1b2c3d'),
    issuersConfigMap: output('pepys-imp-issuers-0a1b2c3d'),
    pullSecret: 'ghcr-pull',
  });

  expect(spec.template.spec?.containers[0]?.env).toStrictEqual([
    { name: 'PEPYS_INGEST_HOST', value: '0.0.0.0' },
    { name: 'PEPYS_INGEST_PORT', value: '8080' },
    { name: 'PEPYS_S2_ENDPOINT', value: 'http://pepys-s2.pepys.svc.cluster.local:8080' },
    { name: 'PEPYS_S2_BASIN', value: 'pepys-facts' },
    { name: 'PEPYS_IMP_IDENTITY_ISSUERS', value: '/etc/pepys/imp-issuers' },
  ]);
});

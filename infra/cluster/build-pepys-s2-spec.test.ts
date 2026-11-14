import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildPepysS2Spec } from './build-pepys-s2-spec.ts';

test('it runs one s2-lite on the facts bucket in Garage, replaced before its successor starts', () => {
  const envSecret = output('pepys-s2-0a1b2c3d');

  const spec = buildPepysS2Spec({
    image:
      'ghcr.io/s2-streamstore/s2:0.43.2@sha256:6666666666666666666666666666666666666666666666666666666666666666',
    envSecret,
  });

  expect(spec.replicas).toBe(1);
  expect(spec.strategy).toStrictEqual({ type: 'Recreate' });

  expect(spec.template.spec?.containers[0]).toMatchObject({
    args: ['lite', '--bucket', 'facts', '--path', 's2lite', '--port', '8080'],
    env: [
      { name: 'AWS_ENDPOINT_URL_S3', value: 'http://pepys-garage.pepys.svc.cluster.local:3900' },
      { name: 'AWS_REGION', value: 'garage' },
      { name: 'RUST_LOG', value: 'info' },
    ],
    envFrom: [{ secretRef: { name: envSecret } }],
  });
});

test('it limits s2-lite to 1536Mi of memory', () => {
  const spec = buildPepysS2Spec({
    image:
      'ghcr.io/s2-streamstore/s2:0.43.2@sha256:6666666666666666666666666666666666666666666666666666666666666666',
    envSecret: output('pepys-s2-0a1b2c3d'),
  });

  expect(spec.template.spec?.containers[0]).toMatchObject({
    resources: { requests: { cpu: '50m', memory: '256Mi' }, limits: { memory: '1536Mi' } },
  });
});

import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildPepysGarageSpec } from './build-pepys-garage-spec.ts';

test('it runs one single-node Garage as nonroot, with its secrets from the Secret and two retained volumes', () => {
  const configMap = output('pepys-garage-config-0a1b2c3d');
  const envSecret = output('pepys-garage-0a1b2c3d');

  const spec = buildPepysGarageSpec({
    image:
      'dxflrs/garage:v2.5.0@sha256:5555555555555555555555555555555555555555555555555555555555555555',
    serviceName: output('pepys-garage'),
    configMap,
    envSecret,
  });

  expect(spec.replicas).toBe(1);

  expect(spec.template.spec?.securityContext).toStrictEqual({
    fsGroup: 65_532,
    runAsNonRoot: true,
    runAsUser: 65_532,
    runAsGroup: 65_532,
    seccompProfile: { type: 'RuntimeDefault' },
  });

  expect(spec.template.spec?.containers[0]).toMatchObject({
    command: ['/garage', 'server', '--single-node'],
    env: [{ name: 'GARAGE_CONFIG_FILE', value: '/etc/garage/garage.toml' }],
    envFrom: [{ secretRef: { name: envSecret } }],
    securityContext: {
      allowPrivilegeEscalation: false,
      readOnlyRootFilesystem: true,
      capabilities: { drop: ['ALL'] },
    },
  });

  expect(spec.volumeClaimTemplates).toStrictEqual([
    {
      metadata: { name: 'meta' },
      spec: {
        accessModes: ['ReadWriteOnce'],
        storageClassName: 'local-path-retain',
        resources: { requests: { storage: '1Gi' } },
      },
    },
    {
      metadata: { name: 'data' },
      spec: {
        accessModes: ['ReadWriteOnce'],
        storageClassName: 'local-path-retain',
        resources: { requests: { storage: '20Gi' } },
      },
    },
  ]);
});

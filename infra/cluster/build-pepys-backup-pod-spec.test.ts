import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildPepysBackupPodSpec } from './build-pepys-backup-pod-spec.ts';

test('it runs the backup script on each bucket a store writes, with Garage and R2 as rclone remotes', () => {
  const envSecret = output('pepys-backup-0a1b2c3d');
  const scriptConfigMap = output('pepys-backup-script-0a1b2c3d');

  const spec = buildPepysBackupPodSpec({
    image:
      'rclone/rclone:1.71.2@sha256:7777777777777777777777777777777777777777777777777777777777777777',
    scriptConfigMap,
    envSecret,
  });

  expect(spec.restartPolicy).toBe('OnFailure');

  expect(spec.containers[0]).toMatchObject({
    command: ['/bin/sh', '/opt/pepys-backup/backup.sh', 'facts'],
    env: [
      { name: 'HOME', value: '/tmp' },
      { name: 'RCLONE_CONFIG_GARAGE_TYPE', value: 's3' },
      { name: 'RCLONE_CONFIG_GARAGE_PROVIDER', value: 'Other' },
      {
        name: 'RCLONE_CONFIG_GARAGE_ENDPOINT',
        value: 'http://pepys-garage.pepys.svc.cluster.local:3900',
      },
      { name: 'RCLONE_CONFIG_GARAGE_REGION', value: 'garage' },
      { name: 'RCLONE_CONFIG_R2_TYPE', value: 's3' },
      { name: 'RCLONE_CONFIG_R2_PROVIDER', value: 'Cloudflare' },
    ],
    envFrom: [{ secretRef: { name: envSecret } }],
  });

  expect(spec.volumes).toContainEqual({ name: 'script', configMap: { name: scriptConfigMap } });
});

import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildPepysBackupCronJobSpec } from './build-pepys-backup-cron-job-spec.ts';
import { buildPepysBackupPodSpec } from './build-pepys-backup-pod-spec.ts';

test('it runs the backup pod at 04:00 UTC each day, one Job at a time', () => {
  const scriptConfigMap = output('pepys-backup-script-0a1b2c3d');
  const envSecret = output('pepys-backup-0a1b2c3d');

  expect(
    buildPepysBackupCronJobSpec({
      image:
        'rclone/rclone:1.70.0@sha256:5555555555555555555555555555555555555555555555555555555555555555',
      scriptConfigMap,
      envSecret,
    }),
  ).toStrictEqual({
    schedule: '0 4 * * *',
    timeZone: 'Etc/UTC',
    suspend: false,
    concurrencyPolicy: 'Forbid',
    jobTemplate: {
      spec: {
        backoffLimit: 2,
        template: {
          metadata: { labels: { app: 'pepys-backup' } },
          spec: buildPepysBackupPodSpec({
            image:
              'rclone/rclone:1.70.0@sha256:5555555555555555555555555555555555555555555555555555555555555555',
            scriptConfigMap,
            envSecret,
          }),
        },
      },
    },
  });
});

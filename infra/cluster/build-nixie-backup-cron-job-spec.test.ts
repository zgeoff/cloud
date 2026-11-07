import { expect, test } from 'bun:test';
import { buildNixieBackupCronJobSpec } from './build-nixie-backup-cron-job-spec.ts';
import { buildNixieBackupPodSpec } from './build-nixie-backup-pod-spec.ts';

test('it runs the backup pod nightly, one Job at a time, and fails a Job at its first failed pod', () => {
  expect(
    buildNixieBackupCronJobSpec({
      image:
        'ghcr.io/zgeoff/nixie-backup:1.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111',
      claim: 'data-nixie-0',
      envSecret: 'nixie-backup',
      pullSecret: 'ghcr-pull',
    }),
  ).toStrictEqual({
    schedule: '0 4 * * *',
    timeZone: 'Australia/Melbourne',
    suspend: false,
    concurrencyPolicy: 'Forbid',
    jobTemplate: {
      spec: {
        backoffLimit: 0,
        template: {
          spec: buildNixieBackupPodSpec({
            image:
              'ghcr.io/zgeoff/nixie-backup:1.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111',
            claim: 'data-nixie-0',
            envSecret: 'nixie-backup',
            pullSecret: 'ghcr-pull',
          }),
        },
      },
    },
  });
});

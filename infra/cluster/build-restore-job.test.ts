import { expect, test } from 'bun:test';
import { buildRestoreJob } from './build-restore-job.ts';

test('it runs the restore pod once, in a one-off Job that names itself for the workload', () => {
  expect(
    buildRestoreJob({
      name: 'ledger',
      namespace: 'books',
      pod: {
        restartPolicy: 'Never',
        containers: [{ name: 'restore', image: 'ghcr.io/zgeoff/ledger-restore:1.0.0' }],
      },
    }),
  ).toStrictEqual({
    apiVersion: 'batch/v1',
    kind: 'Job',
    metadata: { generateName: 'ledger-restore-', namespace: 'books' },
    spec: {
      backoffLimit: 0,
      ttlSecondsAfterFinished: 86_400,
      template: {
        spec: {
          restartPolicy: 'Never',
          containers: [{ name: 'restore', image: 'ghcr.io/zgeoff/ledger-restore:1.0.0' }],
        },
      },
    },
  });
});
